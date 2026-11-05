# test_selection.jl — per-mutant test selection (TestPlan) and outcome reuse (ResultStore)
#
# Uses a fake TestSelector, so it needs neither Fallout nor Julia >= 1.12. The Fallout-backed
# selector itself is exercised by test_fallout.jl when Fallout is loadable.

using Test
using Gremlins
using Gremlins: TestSelector, MutantResult, RunResult, MutationSite

"""
A selector that names testsets by the function a site lies in, and reports `changed` (a
Set, or `nothing`) for every anchor it is asked about.
"""
mutable struct FakeSelector <: TestSelector
    pick::Function                       # site -> Vector{String}
    changed::Union{Set{String}, Nothing}
    asked::Vector{String}                # anchors changed_testsets was asked about
end
FakeSelector(pick) = FakeSelector(pick, Set{String}(), String[])

Gremlins.selected_tests(s::FakeSelector, site::MutationSite, ::AbstractString) = s.pick(site)
Gremlins.runner_arguments(::FakeSelector, names) = ["regex:" * join(names, ",")]
Gremlins.runner_path(::FakeSelector) = "test/select.jl"
Gremlins.selector_summary(::FakeSelector) = "fake selector"
function Gremlins.changed_testsets(s::FakeSelector, anchor::AbstractString)
    push!(s.asked, anchor)
    return s.changed
end

const SEL_FIXTURE = joinpath(@__DIR__, "fixtures", "MiniTarget")

"MiniTarget's testsets, by the function a site lies in (multiply has none)."
function minitarget_pick(site::MutationSite)::Vector{String}
    site.line <= 9  && return ["adds"]
    site.line <= 18 && return ["positives"]
    return String[]
end

gitq(dir, args...) = readchomp(`git -C $dir -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null $args`)

"A copy of MiniTarget in a fresh git repository, with runners that log their ARGS."
function selection_fixture()::String
    dir = mktempdir()
    cp(SEL_FIXTURE, dir; force = true)
    log_line = """open(ENV["GREMLINS_SELECTION_LOG"], "a") do io
        println(io, isempty(ARGS) ? "<none>" : join(ARGS, "|"))
    end
    """
    write(joinpath(dir, "test", "select.jl"), log_line * "include(\"runtests.jl\")\n")
    write(joinpath(dir, "test", "select_warm.jl"), log_line * "include(\"runtests_warm.jl\")\n")
    gitq(dir, "init", "-q")
    gitq(dir, "add", "-A")
    gitq(dir, "commit", "-q", "-m", "fixture")
    return dir
end

"Three sites: + in add (killable), > in is_positive (survives), * in multiply (no testset)."
function selection_sites(dir)::Vector{MutationSite}
    sites = discover(joinpath(dir, "src"); root = dir,
        operators = [OP_PLUS_TO_MINUS, OP_GT_TO_GE, OP_MUL_TO_DIV])
    @assert length(sites) == 3 "expected 3 sites, got $(length(sites))"
    return sites
end

@testset "Selection — plan" begin
    dir = selection_fixture()
    sites = selection_sites(dir)
    plan = plan_tests(FakeSelector(minitarget_pick), dir, sites)
    @test plan.runner == "test/select.jl"
    by_op = Dict(s.op_id => s for s in sites)
    @test Gremlins.planned_tests(plan, by_op[:arith_plus_minus]) == ["adds"]
    @test Gremlins.planned_tests(plan, by_op[:relop_gt_ge]) == ["positives"]
    @test Gremlins.unreachable(plan, by_op[:arith_mul_div])
    @test !Gremlins.unreachable(plan, by_op[:arith_plus_minus])
    @test !Gremlins.unreachable(nothing, by_op[:arith_mul_div])
    @test Gremlins.plan_arguments(plan, by_op[:relop_gt_ge]) == ["regex:positives"]
    @test Gremlins.plan_arguments(nothing, by_op[:relop_gt_ge]) == String[]
    @test Gremlins.planned_union(plan, sites) == ["adds", "positives"]
    @test Gremlins.plan_test_relpath(plan, "test", "runtests.jl") == "test/select.jl"
    @test Gremlins.plan_test_relpath(nothing, "test", "runtests.jl") == joinpath("test", "runtests.jl")
end

@testset "Selection — mutant keys follow the statement, not the byte offset" begin
    dir = selection_fixture()
    path = joinpath(dir, "src", "MiniTarget.jl")
    original = read(path, String)
    keys_of(sites) = Dict(s.op_id => k for (s, k) in
        ((s, Gremlins.mutant_keys(dir, sites)[s.id]) for s in sites))
    before = keys_of(selection_sites(dir))
    @test length(unique(values(before))) == 3

    # An edit above every site moves their bytes, so their ids change; their keys do not.
    write(path, replace(original, "module MiniTarget\n" => "module MiniTarget\nconst EXTRA = 1\n"))
    moved = selection_sites(dir)
    @test keys_of(moved) == before

    # An edit inside add's statement makes a new key for add's mutant only.
    write(path, replace(original, "return a + b" => "return a + b  # sum"))
    edited = keys_of(selection_sites(dir))
    @test edited[:arith_plus_minus] != before[:arith_plus_minus]
    @test edited[:relop_gt_ge] == before[:relop_gt_ge]
    write(path, original)

    tree = Gremlins.JuliaSyntax.parseall(Gremlins.JuliaSyntax.SyntaxNode, original)
    byte = findfirst("return a + b", original)[1] + length("return ")
    statement = original[Gremlins._statement_range(tree, byte)]
    @test startswith(statement, "function add(a, b)")
    @test endswith(statement, "end")
end

@testset "Selection — git snapshot leaves the repository alone" begin
    dir = selection_fixture()
    write(joinpath(dir, "src", "MiniTarget.jl"), read(joinpath(dir, "src", "MiniTarget.jl"), String) * "# edit\n")
    write(joinpath(dir, "untracked.txt"), "new\n")
    status = gitq(dir, "status", "--porcelain")
    head = gitq(dir, "rev-parse", "HEAD")
    snapshot = Gremlins.git_snapshot(dir)
    @test snapshot isa String && length(snapshot) == 40
    @test gitq(dir, "status", "--porcelain") == status
    @test gitq(dir, "rev-parse", "HEAD") == head
    @test gitq(dir, "show", "$snapshot:untracked.txt") == "new"
    @test endswith(gitq(dir, "show", "$snapshot:src/MiniTarget.jl"), "# edit")
    @test gitq(dir, "rev-parse", "$snapshot^") == head
    @test Gremlins.git_snapshot(mktempdir()) === nothing
end

@testset "Selection — result store round trip" begin
    dir = mktempdir()
    store = load_results(dir)
    @test isempty(store.entries)
    store.entries["k1"] = Gremlins.StoredResult(Gremlins.killed, 1.5, ["a", "b"], "c0ffee", "src/X.jl", false)
    store.entries["k2"] = Gremlins.StoredResult(Gremlins.no_coverage, 0.0, ["a"], "c0ffee", "src/X.jl", true)
    save_results(store)
    again = load_results(dir)
    @test again.entries["k1"].outcome == Gremlins.killed
    @test again.entries["k1"].testsets == ["a", "b"]
    @test again.entries["k1"].anchor == "c0ffee"
    @test !again.entries["k1"].warm
    @test again.entries["k2"].warm
    # Another Gremlins version's store is ignored.
    path = joinpath(dir, Gremlins.RESULT_STORE_FILE)
    write(path, replace(read(path, String), Gremlins.GREMLINS_VERSION => "0.0.0-other"))
    @test isempty(load_results(dir).entries)
    write(path, "not = [toml")
    @test isempty((@test_logs (:warn,) load_results(dir)).entries)
end

"A finished run of `prepared`'s pending sites with the given outcome per op id."
function fake_run(prepared, outcomes::Dict{Symbol, Gremlins.MutantOutcome})
    results = [MutantResult(s, outcomes[s.op_id], 0.1, "") for s in prepared.pending]
    return RunResult(prepared.pkgdir, prepared.pending, results, 1.0, 1.0)
end

@testset "Selection — reuse rules" begin
    dir = selection_fixture()
    write(joinpath(dir, ".gitignore"), ".gremlins_results.toml\n")
    sites = selection_sites(dir)
    selector = FakeSelector(minitarget_pick)
    verdicts = Dict(:arith_plus_minus => Gremlins.killed, :relop_gt_ge => Gremlins.survived,
                    :arith_mul_div => Gremlins.no_coverage)

    first_run = Gremlins.prepare_selected_run(dir, sites, selector)
    @test isempty(first_run.reused)
    @test length(first_run.pending) == 3
    merged = Gremlins.finish_selected_run(first_run, fake_run(first_run, verdicts))
    @test [r.site.id for r in merged.results] == sort([s.id for s in sites])
    store = load_results(dir)
    # multiply's mutant has no testset: nothing to store, it costs nothing to redo.
    @test length(store.entries) == 2

    # Nothing changed: both verdicts come back, without running anything.
    second = Gremlins.prepare_selected_run(dir, sites, selector)
    @test Set(r.site.op_id for r in second.reused) == Set([:arith_plus_minus, :relop_gt_ge])
    @test [s.op_id for s in second.pending] == [:arith_mul_div]
    @test Dict(r.site.op_id => r.outcome for r in second.reused) ==
        Dict(:arith_plus_minus => Gremlins.killed, :relop_gt_ge => Gremlins.survived)
    @test Gremlins.selected_baseline(second)[1] == 0.0   # no pending mutant has a testset
    finished = Gremlins.finish_selected_run(second, fake_run(second, verdicts))
    @test Dict(r.site.op_id => r.outcome for r in finished.results) == verdicts

    # A changed testset reruns the mutants that run it, and only those. The tree must change
    # too: the selector is not asked about a tree the verdicts were made on.
    write(joinpath(dir, "NOTES.md"), "a change outside the sources\n")
    selector.changed = Set(["positives"])
    third = Gremlins.prepare_selected_run(dir, sites, selector)
    @test Set(s.op_id for s in third.pending) == Set([:relop_gt_ge, :arith_mul_div])
    @test !isempty(selector.asked)

    # A change the selector cannot judge reruns everything.
    selector.changed = nothing
    @test length(Gremlins.prepare_selected_run(dir, sites, selector).pending) == 3
    selector.changed = Set{String}()

    # Different testsets than recorded: run again.
    other = FakeSelector(s -> s.line <= 9 ? ["adds", "more"] : minitarget_pick(s))
    @test Set(s.op_id for s in Gremlins.prepare_selected_run(dir, sites, other).pending) ==
        Set([:arith_plus_minus, :arith_mul_div])

    # fresh ignores the store; reuse=false does not even read it.
    @test length(Gremlins.prepare_selected_run(dir, sites, selector; fresh = true).pending) == 3
    unused = Gremlins.prepare_selected_run(dir, sites, selector; reuse = false)
    @test length(unused.pending) == 3 && unused.store === nothing

    # Scoping a run to some sites keeps the verdicts of the others.
    plus_only = filter(s -> s.op_id == :arith_plus_minus, sites)
    scoped = Gremlins.prepare_selected_run(dir, plus_only, selector; fresh = true)
    Gremlins.finish_selected_run(scoped, fake_run(scoped, verdicts))
    @test length(load_results(dir).entries) == 2
    # An entry whose anchor commit git no longer has expires.
    store = load_results(dir)
    stale_key = first(k for (k, e) in store.entries if e.relpath == "src/MiniTarget.jl")
    old = store.entries[stale_key]
    store.entries["gone"] = Gremlins.StoredResult(old.outcome, old.elapsed, old.testsets, "0"^40, old.relpath, false)
    save_results(store)
    expiring = Gremlins.prepare_selected_run(dir, plus_only, selector)
    Gremlins.finish_selected_run(expiring, fake_run(expiring, verdicts))
    @test !haskey(load_results(dir).entries, "gone")
    @test length(load_results(dir).entries) == 2

    # A timeout is not kept: it says more about the run than the mutant.
    timed = Gremlins.prepare_selected_run(dir, sites, selector; fresh = true)
    Gremlins.finish_selected_run(timed, fake_run(timed, merge(verdicts, Dict(:relop_gt_ge => Gremlins.timeout))))
    @test [s.op_id for s in Gremlins.prepare_selected_run(dir, sites, selector).pending] ==
        sort([:relop_gt_ge, :arith_mul_div], by = op -> only(s.id for s in sites if s.op_id == op))
end

@testset "Selection — warm verdicts stay out of cold runs" begin
    dir = selection_fixture()
    write(joinpath(dir, ".gitignore"), ".gremlins_results.toml\n")
    sites = selection_sites(dir)
    selector = FakeSelector(minitarget_pick)
    prepared = Gremlins.prepare_selected_run(dir, sites, selector; warm = true)
    ran = fake_run(prepared, Dict(:arith_plus_minus => Gremlins.survived, :relop_gt_ge => Gremlins.survived,
                                  :arith_mul_div => Gremlins.no_coverage))
    plus = only(s for s in prepared.pending if s.op_id == :arith_plus_minus)
    warm_results = [Gremlins.WarmMutantResult(r, Gremlins.warm_ok, r.outcome == Gremlins.no_coverage ? 0.0 : 0.1)
                    for r in ran.results]
    mismatch = "I4 MISMATCH: site=$(plus.id[1:8]) warm=survived cold=killed"
    warm = Gremlins.WarmRunResult(ran, warm_results, Dict(Gremlins.warm_ok => 3), 2, [mismatch], 0, 0)
    finished = Gremlins.finish_selected_run(prepared, warm)
    @test finished.cache_hits == 0
    store = load_results(dir)
    # The verdict I4 contradicted is not stored; the other warm verdict is, marked warm.
    @test length(store.entries) == 1
    @test only(values(store.entries)).warm

    @test Set(s.op_id for s in Gremlins.prepare_selected_run(dir, sites, selector).pending) ==
        Set([:arith_plus_minus, :relop_gt_ge, :arith_mul_div])          # cold: warm verdict not trusted
    again = Gremlins.prepare_selected_run(dir, sites, selector; warm = true)
    @test [r.site.op_id for r in again.reused] == [:relop_gt_ge]        # warm: reused
    finished_again = Gremlins.finish_selected_run(again,
        Gremlins.WarmRunResult(RunResult(dir, MutationSite[], MutantResult[], 0.0, 0.0),
            Gremlins.WarmMutantResult[], Dict{Gremlins.FallbackReason, Int}(), 0, String[], 0, 0))
    @test finished_again.cache_hits == 1
    @test only(values(load_results(dir).entries)).warm   # a reused warm verdict stays warm
end

@testset "Selection — runners pass each mutant its testsets" begin
    dir = selection_fixture()
    sites = selection_sites(dir)
    plan = plan_tests(FakeSelector(minitarget_pick), dir, sites)
    everything = CoverageMap(Dict("src/MiniTarget.jl" => Set(1:40)))
    log = joinpath(mktempdir(), "args.log")
    expected = Dict(:arith_plus_minus => Gremlins.killed, :relop_gt_ge => Gremlins.survived,
                    :arith_mul_div => Gremlins.no_coverage)
    withenv("GREMLINS_SELECTION_LOG" => log) do
        cold = run_mutations(dir, sites, everything; baseline_elapsed = 10.0, plan = plan)
        @test Dict(r.site.op_id => r.outcome for r in cold.results) == expected
        @test sort(readlines(log)) == ["regex:adds", "regex:positives"]

        rm(log)
        warm = run_mutations_warm(dir, sites, everything; baseline_elapsed = 10.0,
            pkg_name = "MiniTarget", plan = plan)
        @test Dict(r.site.op_id => r.outcome for r in warm.run.results) == expected
        @test isempty(warm.i4_mismatches)
        # Warm runs and their I4 cold re-runs alike get the mutant's testsets, never the suite.
        @test Set(readlines(log)) == Set(["regex:adds", "regex:positives"])
    end
end
