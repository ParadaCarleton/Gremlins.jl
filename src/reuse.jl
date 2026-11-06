# reuse.jl — Reusing stored mutant outcomes across runs (Fallout integration)
#
# A selected run (see selection.jl) records each verdict with the testsets that
# produced it and a git snapshot of the tree it ran on. A later run reuses the
# verdict when the mutant is the same (same statement text, offset, operator) and
# runs the same testsets, and the selector finds none of them affected by the
# change from that snapshot to the working tree.
#
# No mtime anywhere: validity comes from the selector's change analysis.

using SHA: sha256

# ─── Result store ─────────────────────────────────────────────────────────────

"""
    StoredResult

An outcome recorded for a mutant: the testsets it ran, the git commit (`anchor`) holding
the tree it ran on, and whether the warm path produced it (a warm verdict can disagree with
a fresh process, which I4 samples for; a cold run reuses only cold verdicts).
"""
struct StoredResult
    outcome::MutantOutcome
    elapsed::Float64
    testsets::Vector{String}
    anchor::String
    relpath::String
    warm::Bool
end

"""
    ResultStore

Outcomes of earlier runs, by mutant key (see `mutant_key`). Stored as TOML at
`<pkgdir>/.gremlins_results.toml`.
"""
struct ResultStore
    path::String
    entries::Dict{String, StoredResult}
end

const RESULT_STORE_FILE = ".gremlins_results.toml"
const RESULT_STORE_SCHEMA = "gremlins-results-v1"

"""
    load_results(pkgdir) -> ResultStore

Load the stored outcomes of `pkgdir`; an empty store when there is no file, or one written
by another version of Gremlins or that does not parse.
"""
function load_results(pkgdir::AbstractString)::ResultStore
    path = joinpath(abspath(pkgdir), RESULT_STORE_FILE)
    entries = Dict{String, StoredResult}()
    isfile(path) || return ResultStore(path, entries)
    document = try
        TOML.parsefile(path)
    catch e
        @warn "[gremlins/selection] ignoring unreadable result store $path: $e"
        return ResultStore(path, entries)
    end
    if get(document, "schema", "") != RESULT_STORE_SCHEMA ||
       get(document, "version", "") != GREMLINS_VERSION
        return ResultStore(path, entries)
    end
    for (key, entry) in get(document, "results", Dict{String, Any}())
        outcome = _parse_outcome(get(entry, "outcome", ""))
        outcome === nothing && continue
        entries[key] = StoredResult(
            outcome,
            Float64(get(entry, "elapsed", 0.0)),
            String[get(entry, "testsets", String[])...],
            String(get(entry, "anchor", "")),
            String(get(entry, "relpath", "")),
            Bool(get(entry, "warm", false)),
        )
    end
    return ResultStore(path, entries)
end

"""
    save_results(store)

Write the store (atomically), sorted by key so the file is stable.
"""
function save_results(store::ResultStore)
    results = Dict{String, Any}(
        key => Dict{String, Any}(
            "outcome" => string(entry.outcome),
            "elapsed" => round(entry.elapsed; digits = 4),
            "testsets" => entry.testsets,
            "anchor" => entry.anchor,
            "relpath" => entry.relpath,
            "warm" => entry.warm,
        ) for (key, entry) in store.entries
    )
    document = Dict{String, Any}(
        "schema" => RESULT_STORE_SCHEMA,
        "version" => GREMLINS_VERSION,
        "results" => results,
    )
    io = IOBuffer()
    TOML.print(io, document; sorted = true)
    _atomic_write(store.path, String(take!(io)))
    return nothing
end

"""
    _statement_range(tree, byte) -> UnitRange{Int}

The byte range of the top-level statement holding `byte`: the outermost node holding it
that is neither the file, a `module`, nor a `begin` block or module body.
"""
function _statement_range(tree::JuliaSyntax.SyntaxNode, byte::Integer)::UnitRange{Int}
    node = tree
    while true
        kids = JuliaSyntax.children(node)
        kids === nothing && return JuliaSyntax.byte_range(node)
        index = findfirst(c -> byte in JuliaSyntax.byte_range(c), kids)
        index === nothing && return JuliaSyntax.byte_range(node)
        child = kids[index]
        JuliaSyntax.kind(child) in (JuliaSyntax.K"module", JuliaSyntax.K"block") ||
            return JuliaSyntax.byte_range(child)
        node = child
    end
end

"""
    mutant_keys(pkgdir, sites) -> Dict{String, String}

A key per site that names the same mutant across edits elsewhere: a hash of the file's
path, the operator, the replacement, the text of the top-level statement holding the site,
and the site's offset in it. An edit to that statement (comments included) makes a new key.
"""
function mutant_keys(pkgdir::AbstractString, sites::Vector{MutationSite})::Dict{String, String}
    keys = Dict{String, String}()
    for (relpath, group) in _group_by_relpath(sites)
        text = read(_find_abs_path_or_throw(pkgdir, first(group)), String)
        tree = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, text; ignore_errors = true)
        for site in group
            range = _statement_range(tree, first(site.byte_range))
            statement = String(codeunits(text)[range])
            offset = first(site.byte_range) - first(range)
            material = join(
                (GREMLINS_VERSION, relpath, string(site.op_id), site.replacement,
                 string(offset), string(length(site.byte_range)), statement),
                '\0',
            )
            keys[site.id] = bytes2hex(sha256(material))
        end
    end
    return keys
end

function _group_by_relpath(sites::Vector{MutationSite})::Dict{String, Vector{MutationSite}}
    groups = Dict{String, Vector{MutationSite}}()
    for site in sites
        push!(get!(groups, site.relpath, MutationSite[]), site)
    end
    return groups
end

"""
    git_snapshot(pkgdir) -> Union{String, Nothing}

A commit object holding the working tree of `pkgdir`'s repository as it is now, untracked
(not ignored) files included, made through a throwaway index: neither the index, the
working tree nor any ref changes. `nothing` outside a git repository. The commit is
unreferenced, so `git gc` may prune it after a while; results anchored to a pruned commit
are simply run again.
"""
function git_snapshot(pkgdir::AbstractString)::Union{String, Nothing}
    dir = abspath(pkgdir)
    success(pipeline(`git -C $dir rev-parse --is-inside-work-tree`; stdout = devnull, stderr = devnull)) ||
        return nothing
    mktempdir() do tmp
        environment = copy(ENV)
        environment["GIT_INDEX_FILE"] = joinpath(tmp, "index")
        for role in ("AUTHOR", "COMMITTER")
            environment["GIT_$(role)_NAME"] = "Gremlins"
            environment["GIT_$(role)_EMAIL"] = "gremlins@localhost"
        end
        git(args...) = readchomp(setenv(`git -C $dir $args`, environment))
        try
            has_head = success(pipeline(setenv(`git -C $dir rev-parse --verify -q HEAD`, environment); stdout = devnull))
            has_head && git("read-tree", "HEAD")
            git("add", "-A")
            tree = git("write-tree")
            parents = has_head ? ["-p", "HEAD"] : String[]
            return git("commit-tree", tree, parents..., "-m", "gremlins: tree mutants ran on")
        catch e
            @warn "[gremlins/selection] could not snapshot the working tree of $dir: $e"
            return nothing
        end
    end
end

"""The tree `sha` (a commit) holds, or `nothing` when the repository of `pkgdir` lacks it."""
function _commit_tree(pkgdir::AbstractString, sha::AbstractString)::Union{String, Nothing}
    out = IOBuffer()
    ok = success(pipeline(`git -C $pkgdir rev-parse -q --verify $(sha * "^{tree}")`; stdout = out, stderr = devnull))
    return ok ? strip(String(take!(out))) : nothing
end

"""Whether `pkgdir`'s repository holds commit `sha`."""
_commit_exists(pkgdir::AbstractString, sha::AbstractString)::Bool =
    success(pipeline(`git -C $pkgdir cat-file -e $(sha * "^{commit}")`; stdout = devnull, stderr = devnull))

# ─── Planning a selected run ──────────────────────────────────────────────────

"""
    SelectedRun

A run with a test selector, before its mutants execute: the plan, the outcomes reused from
the store, and the sites still to run.
"""
struct SelectedRun
    pkgdir::String
    plan::TestPlan
    sites::Vector{MutationSite}          # every site, sorted by id
    keys::Dict{String, String}           # site id → mutant key
    reused::Vector{MutantResult}
    reused_warm::Set{String}             # ids of reused sites whose verdict the warm path made
    pending::Vector{MutationSite}
    store::Union{ResultStore, Nothing}   # nothing: reuse is off
    anchor::Union{String, Nothing}       # commit of the tree this run sees
end

"""
Outcomes worth keeping: a verdict of the mutant's testsets (killed, survived), or their not
running its line (`no_coverage` with testsets; one without testsets costs nothing to redo).
Each holds while the statement and the testsets are unchanged. A timeout or an error says
more about the run than about the mutant, so it runs again.
"""
const REUSABLE_OUTCOMES = (killed, survived, no_coverage)

"""
    prepare_selected_run(pkgdir, sites, selector; warm=false, reuse=true, fresh=false, verbose=false) -> SelectedRun

Plan the tests of every site and, with `reuse`, take from the store the outcome of each
site that ran the same testsets at a tree from which the change to now affects none of
them. `fresh` ignores the stored outcomes but still records this run's. A `warm` run may
reuse verdicts of either path; a cold one only those of the cold path.
"""
function prepare_selected_run(
    pkgdir::AbstractString,
    sites::Vector{MutationSite},
    selector::TestSelector;
    warm::Bool = false,
    reuse::Bool = true,
    fresh::Bool = false,
    verbose::Bool = false,
)::SelectedRun
    pkgdir = abspath(pkgdir)
    sorted = sort(sites, by = s -> s.id)
    plan = plan_tests(selector, pkgdir, sorted)
    keys = mutant_keys(pkgdir, sorted)
    store = nothing
    anchor = nothing
    if reuse
        anchor = git_snapshot(pkgdir)
        if anchor === nothing
            @warn "[gremlins/selection] $pkgdir is not in a git repository: results are not reused"
        else
            store = load_results(pkgdir)
        end
    end

    reused = MutantResult[]
    reused_warm = Set{String}()
    pending = MutationSite[]
    changes = Dict{String, Union{Set{String}, Nothing}}()
    # Snapshots of one tree made in different seconds are different commits: compare trees.
    tree = anchor === nothing ? nothing : _commit_tree(pkgdir, anchor)
    for site in sorted
        entry = (store === nothing || fresh) ? nothing : get(store.entries, keys[site.id], nothing)
        if entry !== nothing && entry.outcome in REUSABLE_OUTCOMES && (warm || !entry.warm) &&
           entry.testsets == planned_tests(plan, site) && !isempty(entry.testsets)
            changed = get!(changes, entry.anchor) do
                same = tree !== nothing && _commit_tree(pkgdir, entry.anchor) == tree
                same ? Set{String}() : changed_testsets(selector, entry.anchor)
            end
            if changed !== nothing && isdisjoint(entry.testsets, changed)
                push!(reused, MutantResult(site, entry.outcome, entry.elapsed, ""))
                entry.warm && push!(reused_warm, site.id)
                continue
            end
        end
        push!(pending, site)
    end
    prepared = SelectedRun(pkgdir, plan, sorted, keys, reused, reused_warm, pending, store, anchor)
    if verbose
        foreach(line -> println("[gremlins/selection] ", line), selection_report(prepared))
    end
    return prepared
end

"""
    selection_report(prepared) -> Vector{String}

Lines describing a prepared selected run: the selector, how many testsets the mutants
run, and how many outcomes were reused.
"""
function selection_report(prepared::SelectedRun)::Vector{String}
    sites = prepared.sites
    plan = prepared.plan
    reached = count(s -> !unreachable(plan, s), sites)
    mean = reached == 0 ? 0.0 : sum(length(planned_tests(plan, s)) for s in sites) / reached
    lines = [
        selector_summary(plan.selector),
        "$(length(sites)) mutants: $(length(sites) - reached) reach no testset, " *
            "the rest run $(round(mean, digits=1)) testsets on average",
    ]
    if prepared.store === nothing
        push!(lines, "outcomes are not reused; $(length(prepared.pending)) mutants to run")
    else
        push!(lines, "reused $(length(prepared.reused)) stored outcomes; $(length(prepared.pending)) mutants to run")
    end
    return lines
end

"""
    selected_baseline(prepared; timeout=600.0) -> (elapsed, CoverageMap)

The baseline coverage run for a selected run: the runner with the union of the testsets
the pending mutants run. Nothing runs (and the map is empty) when no pending mutant has a
testset.
"""
function selected_baseline(prepared::SelectedRun; timeout::Float64 = 600.0)::Tuple{Float64, CoverageMap}
    names = planned_union(prepared.plan, prepared.pending)
    isempty(names) && return (0.0, CoverageMap(Dict{String, Set{Int}}()))
    return baseline_run(prepared.pkgdir;
        test_dir = dirname(prepared.plan.runner),
        test_file = basename(prepared.plan.runner),
        test_args = runner_arguments(prepared.plan.selector, names),
        timeout = timeout)
end

"""
    finish_selected_run(prepared, result) -> result with the reused outcomes merged in

Merge the reused outcomes into `result` (a `RunResult` or `WarmRunResult` of the pending
sites), in site order, and record every verdict in the store, anchored to this run's tree.
"""
function finish_selected_run(prepared::SelectedRun, result::RunResult)::RunResult
    merged = _merge_results(prepared, result.results)
    _record!(prepared, merged, prepared.reused_warm)
    return RunResult(result.pkgdir, prepared.sites, merged, result.baseline_elapsed, result.total_elapsed)
end

function finish_selected_run(prepared::SelectedRun, result::WarmRunResult)::WarmRunResult
    merged = _merge_results(prepared, result.run.results)
    ran_warm = Set(wr.base.site.id for wr in result.warm_results if wr.fallback_reason == warm_ok && wr.warm_elapsed > 0)
    # A warm verdict the I4 cold re-run contradicted is not kept: the next run tries it again.
    contradicted = Set(
        s.id for s in prepared.sites
        if any(m -> occursin("site=$(first(s.id, 8)) ", m), result.i4_mismatches)
    )
    _record!(prepared, merged, union(prepared.reused_warm, ran_warm); skip = contradicted)
    by_id = Dict(wr.base.site.id => wr for wr in result.warm_results)
    warm = WarmMutantResult[
        haskey(by_id, r.site.id) ? by_id[r.site.id] : WarmMutantResult(r, warm_ok, 0.0)
        for r in merged
    ]
    taxonomy = copy(result.fallback_taxonomy)
    isempty(prepared.reused) || (taxonomy[warm_ok] = get(taxonomy, warm_ok, 0) + length(prepared.reused))
    run = RunResult(result.run.pkgdir, prepared.sites, merged, result.run.baseline_elapsed, result.run.total_elapsed)
    return WarmRunResult(run, warm, taxonomy, result.i4_sample_count, result.i4_mismatches,
        result.cache_hits + length(prepared.reused), result.worker_recycles)
end

function _merge_results(prepared::SelectedRun, ran::Vector{MutantResult})::Vector{MutantResult}
    by_id = Dict(r.site.id => r for r in vcat(prepared.reused, ran))
    return MutantResult[
        get(by_id, s.id) do
            MutantResult(s, error, 0.0, "selected run: no result for this site")
        end
        for s in prepared.sites
    ]
end

function _record!(
    prepared::SelectedRun,
    results::Vector{MutantResult},
    warm_ids::Set{String};
    skip::Set{String} = Set{String}(),
)
    store = prepared.store
    (store === nothing || prepared.anchor === nothing) && return nothing
    # Entries expire with their anchor: a verdict this run reused or made is re-anchored to
    # this run's tree below, so an entry left on an old anchor belongs to a mutant no run
    # has seen since (its statement changed, or runs were scoped elsewhere). When `git gc`
    # prunes that anchor the entry can no longer be validated, so it goes.
    anchors = Set(entry.anchor for entry in values(store.entries) if entry.anchor != prepared.anchor)
    gone = Set(a for a in anchors if !_commit_exists(prepared.pkgdir, a))
    filter!(pair -> !(last(pair).anchor in gone), store.entries)
    for r in results
        key = prepared.keys[r.site.id]
        tests = planned_tests(prepared.plan, r.site)
        if r.outcome in REUSABLE_OUTCOMES && !isempty(tests) && !(r.site.id in skip)
            store.entries[key] = StoredResult(
                r.outcome, r.elapsed, tests, prepared.anchor, r.site.relpath, r.site.id in warm_ids,
            )
        else
            delete!(store.entries, key)
        end
    end
    save_results(store)
    return nothing
end
