# GremlinsFalloutExt — Gremlins' TestSelector over a Fallout.jl test impact map.
#
# Loaded when Fallout is loaded next to Gremlins (`using Gremlins, Fallout`).
# Construct through `Gremlins.fallout_selector(pkgdir; map, build)`.
module GremlinsFalloutExt

using Gremlins
using Gremlins: MutationError, MutationSite
using Fallout

"""
    FalloutSelector(pkgdir; map="test-impact-map.toml", build=true, refresh=true, jobs, timeout=3600, environment=[])

A `TestSelector` that gives a mutant the testsets Fallout selects for the edit the mutant
makes, and tells which testsets the change from an earlier commit affects.

With `refresh` (the default), the map is first brought up to the working tree
(`Fallout.refresh_map` at a snapshot commit of it): a coverage map re-runs, under coverage, the
testsets the changes since its commit reach, `jobs` at a time with `environment` set (what
`fallout build --env` sets), so selection never trusts coverage of code that has changed. An
absent map is built statically. Without `refresh`, an absent map is built statically at `HEAD`
when `build` is set, and a stale map is used as it is: every mutant then also runs the testsets
the change since the map's commit reaches, as `fallout select` would.
"""
struct FalloutSelector <: Gremlins.TestSelector
    root::String
    map_path::String
    editor::Fallout.EditSelector
    all::Vector{String}          # every runnable testset: what an edit Fallout cannot place runs
    stale::Vector{String}        # testsets the change from the map's commit to now reaches
    refreshed::Union{Nothing, Vector{String}}  # testsets the refresh ran; nothing: no refresh
    warned::Set{String}          # files already reported as outside the map's sources
end

function FalloutSelector(
    pkgdir::AbstractString;
    map::AbstractString = "test-impact-map.toml",
    build::Bool = true,
    refresh::Bool = true,
    jobs::Integer = max(1, Sys.CPU_THREADS),
    timeout::Integer = 3600,
    environment::AbstractVector{Pair{String, String}} = Pair{String, String}[],
)::FalloutSelector
    root = abspath(pkgdir)
    toplevel = try
        realpath(readchomp(pipeline(`git -C $root rev-parse --show-toplevel`; stderr = devnull)))
    catch
        ""
    end
    if toplevel != realpath(root)
        throw(MutationError(
            "fallout_selector: the package must be the root of a git repository; " *
                "git sees $(isempty(toplevel) ? "no repository" : toplevel) for $root",
        ))
    end
    map_path = abspath(root, map)
    refreshed = nothing
    if refresh
        snapshot = Gremlins.git_snapshot(root)
        snapshot === nothing && throw(MutationError("fallout_selector: cannot snapshot the working tree of $root"))
        refreshed = try
            Fallout.refresh_map(root, snapshot; map = map_path, jobs = jobs, timeout = timeout,
                environment = collect(Pair{String, String}, environment))
        catch e
            throw(MutationError(
                "fallout_selector: cannot refresh the test impact map $map_path: $(sprint(showerror, e))",
            ))
        end
    end
    editor = try
        Fallout.EditSelector(root; map = map_path, build = build && !refresh)
    catch e
        throw(MutationError(
            "fallout_selector: cannot use the test impact map $map_path: $(sprint(showerror, e))",
        ))
    end
    stale = try
        Fallout.affected_testsets(Fallout.select_testsets(root, editor.map, editor.map.commit, ""))
    catch
        String[]
    end
    return FalloutSelector(root, map_path, editor, Fallout.testset_names(editor), stale, refreshed, Set{String}())
end

function Gremlins.selected_tests(
    selector::FalloutSelector,
    site::MutationSite,
    mutated_text::AbstractString,
)::Vector{String}
    selection = try
        Fallout.select_edit(selector.editor, site.relpath, mutated_text)
    catch e
        # A file outside the map's sources, or a mutant Fallout cannot parse: Fallout cannot
        # say what it affects, so every testset runs.
        if !(site.relpath in selector.warned)
            push!(selector.warned, site.relpath)
            @warn "[gremlins/fallout] cannot select tests for mutants of $(site.relpath); they run every testset" exception = e
        end
        return selector.all
    end
    return Fallout.testset_names(selection)
end

Gremlins.runner_arguments(selector::FalloutSelector, names::AbstractVector{<:AbstractString})::Vector{String} =
    Fallout.runner_arguments(!isempty(selector.editor.map.suites), names)

Gremlins.runner_path(selector::FalloutSelector)::String = selector.editor.map.runner

function Gremlins.changed_testsets(selector::FalloutSelector, anchor::AbstractString)::Union{Set{String}, Nothing}
    # `git gc` prunes old snapshots; such an anchor cannot be judged.
    present = success(pipeline(`git -C $(selector.root) cat-file -e $(anchor * "^{commit}")`; stdout = devnull, stderr = devnull))
    present || return nothing
    selection = try
        Fallout.select_testsets(selector.root, selector.editor.map, anchor, "")
    catch
        return nothing   # the anchor commit is gone (pruned), or the tree does not parse
    end
    isempty(selection.full) || return nothing
    # Static-analysis, partial-coverage and unmapped testsets are selected for any `.jl` edit
    # and sit in every mutant's plan: counting them would let any edit anywhere invalidate
    # every stored outcome. `affected_testsets` keeps them only when the change reaches them.
    return Set(Fallout.affected_testsets(selection))
end

function Gremlins.selector_summary(selector::FalloutSelector)::String
    map = selector.editor.map
    line = "Fallout map $(relpath(selector.map_path, selector.root)) at $(first(map.commit, 12)): " *
        "$(length(selector.all)) testsets, runner $(map.runner)"
    if selector.refreshed !== nothing
        line *= "; refreshed to the working tree ($(length(selector.refreshed)) testsets re-run under coverage)"
    end
    if !isempty(selector.stale)
        line *= "; $(length(selector.stale)) testsets run code changed since the map's commit, " *
            "so every mutant runs them (refresh the map, the default, or rebuild it with `fallout build`)"
    end
    return line
end

end # module GremlinsFalloutExt
