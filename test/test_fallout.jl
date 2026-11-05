# test_fallout.jl — the Fallout-backed TestSelector (GremlinsFalloutExt), end to end.
#
# Needs Fallout.jl (unregistered, Julia >= 1.12) loadable from the test environment, e.g.
#   JULIA_LOAD_PATH="@:/path/to/env-with-Fallout:@stdlib" julia --project test/runtests.jl fallout
# Skipped otherwise; test_selection.jl covers the selection logic with a fake selector.

using Test
using Gremlins

if VERSION < v"1.12" || Base.find_package("Fallout") === nothing
    @info "skipping test_fallout.jl: Fallout.jl is not loadable (it needs Julia >= 1.12)"
else

@eval using Fallout

const FALLOUT_PKG = """
module P
add(x, y) = x + y
function clamp01(x)
    if x < 0
        return 0
    elseif x > 1
        return 1
    end
    return x
end
twice(x) = 2 * x
untested(x) = x - 1
end
"""

const FALLOUT_TESTS = """
using Test
using P
@testset "add" begin
    @test P.add(1, 2) == 3
end
@testset "clamp" begin
    @test P.clamp01(-1) == 0
    @test P.clamp01(0.5) == 0.5
end
@testset "twice" begin
    @test P.twice(2) == 4
end
"""

# A ReTest-style runner: runs the testsets of runtests.jl whose `/name` matches ARGS[1].
const FALLOUT_RUNNER = """
using Test
using P
const PATTERN = isempty(ARGS) ? r"" : Regex(only(ARGS))
for expression in Meta.parseall(read(joinpath(@__DIR__, "runtests.jl"), String)).args
    if Meta.isexpr(expression, :macrocall) && first(expression.args) == Symbol("@testset")
        occursin(PATTERN, "/" * expression.args[3]) || continue
    end
    Core.eval(Main, expression)
end
"""

fgit(dir, args...) = readchomp(`git -C $dir -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null $args`)

"A package in a fresh git repository, mapped by a Fallout coverage build."
function fallout_fixture()::String
    root = mktempdir()
    mkpath(joinpath(root, "src"))
    mkpath(joinpath(root, "test"))
    write(joinpath(root, "Project.toml"),
        "name = \"P\"\nuuid = \"f0000000-0000-4000-8000-000000000001\"\nversion = \"0.1.0\"\n")
    write(joinpath(root, "src", "P.jl"), FALLOUT_PKG)
    write(joinpath(root, "test", "runtests.jl"), FALLOUT_TESTS)
    write(joinpath(root, "test", "retest.jl"), FALLOUT_RUNNER)
    write(joinpath(root, ".gitignore"), "test-impact-map.toml*\n.gremlins_*\nManifest.toml\n")
    fgit(root, "init", "-q")
    fgit(root, "add", "-A")
    fgit(root, "commit", "-q", "-m", "base")
    redirect_stdout(devnull) do
        Fallout.main(["build", "--root", root, "--runner", "test/retest.jl", "--jobs", "3", "--timeout", "300"])
    end
    return root
end

const FALLOUT_OPS = [OP_PLUS_TO_MINUS, OP_MINUS_TO_PLUS, OP_MUL_TO_DIV, OP_GT_TO_GE, OP_LT_TO_LE]

@testset "Fallout selector — plan, run, reuse" begin
    root = fallout_fixture()
    selector = fallout_selector(root)
    @test selector isa Gremlins.TestSelector
    @test occursin("3 testsets", Gremlins.selector_summary(selector))
    @test Gremlins.runner_path(selector) == "test/retest.jl"
    @test Gremlins.runner_arguments(selector, ["twice"]) == [Fallout.retest_pattern(["twice"])]

    sites = discover(joinpath(root, "src"); root = root, operators = FALLOUT_OPS)
    plan = plan_tests(selector, root, sites)
    function_of(site) = site.line == 2 ? :add : site.line <= 10 ? :clamp01 : site.line == 11 ? :twice : :untested
    for site in sites
        expected = Dict(:add => ["add"], :clamp01 => ["clamp"], :twice => ["twice"], :untested => String[])
        @test Gremlins.planned_tests(plan, site) == expected[function_of(site)]
    end

    # The selected run reaches the verdicts of the whole suite.
    whole = mutate(root; operators = FALLOUT_OPS)
    selected = mutate(root; operators = FALLOUT_OPS, selector = selector)
    verdicts(r) = Dict(x.site.id => x.outcome for x in r.results)
    @test verdicts(selected) == verdicts(whole)
    @test count(x -> x.outcome == Gremlins.killed, selected.results) > 0
    @test count(x -> x.outcome == Gremlins.survived, selected.results) > 0

    # Nothing changed: every verdict with a testset is reused.
    again = Gremlins.prepare_selected_run(root, sites, fallout_selector(root))
    @test all(s -> Gremlins.unreachable(again.plan, s), again.pending)
    @test length(again.reused) == count(s -> !Gremlins.unreachable(plan, s), sites)

    # Edit twice() in the working tree: Fallout finds only "twice" changed, so only the
    # mutants that run "twice" (and those without a testset) run again.
    write(joinpath(root, "src", "P.jl"), replace(FALLOUT_PKG, "twice(x) = 2 * x" => "twice(x) = x + x"))
    edited_selector = fallout_selector(root)
    @test Gremlins.changed_testsets(edited_selector, again.anchor) == Set(["twice"])
    edited_sites = discover(joinpath(root, "src"); root = root, operators = FALLOUT_OPS)
    edited = Gremlins.prepare_selected_run(root, edited_sites, edited_selector)
    @test !isempty(edited.reused)
    @test all(s -> Gremlins.planned_tests(edited.plan, s) in (["twice"], String[]), edited.pending)
    @test any(s -> Gremlins.planned_tests(edited.plan, s) == ["twice"], edited.pending)

    # A commit git no longer has cannot be judged.
    @test Gremlins.changed_testsets(edited_selector, "0"^40) === nothing
end

@testset "Fallout selector — refuses a package below its repository's root" begin
    root = mktempdir()
    fgit(root, "init", "-q")
    pkg = joinpath(root, "pkg")
    mkpath(pkg)
    @test_throws Gremlins.MutationError fallout_selector(pkg)
end

end # Fallout loadable
