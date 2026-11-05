# selection.jl — Per-mutant test selection and result reuse (Fallout integration)
#
# A mutant can only be detected by the tests that run the code it changes. A
# `TestSelector` names those tests per mutant, so a mutant runs a handful of
# testsets instead of the whole suite, and a mutant no test can reach is never
# run. The selector also says which testsets the change from an earlier tree
# to the working tree affects, so a mutant whose tests are all unaffected keeps
# the outcome it had then instead of being run again.
#
# The one implementation, `fallout_selector`, lives in the GremlinsFalloutExt
# package extension and needs Fallout.jl loaded (`using Fallout`).
#
# Public API:
#   TestSelector                         — abstract selector interface
#   fallout_selector(pkgdir; map, build) -> TestSelector  (needs `using Fallout`)
#   TestPlan, plan_tests(selector, pkgdir, sites)
#
# Reusing stored outcomes across runs lives in reuse.jl.

# ─── Selector interface ───────────────────────────────────────────────────────

"""
    TestSelector

Chooses the tests that can detect each mutant. A selector implements:

- `selected_tests(selector, site, mutated_text) -> Vector{String}`: the names of the
  testsets that can detect `site`, whose file would hold `mutated_text`. Empty when no
  test runs the mutated code.
- `runner_arguments(selector, names) -> Vector{String}`: the arguments the runner script
  takes to run exactly the testsets `names`.
- `runner_path(selector) -> String`: the runner script, relative to the package root.
- `changed_testsets(selector, anchor) -> Union{Set{String}, Nothing}`: the testsets whose
  outcome the change from git commit `anchor` to the working tree can alter; `nothing`
  when that cannot be told (the commit is gone, the environment changed).
- `selector_summary(selector) -> String`: one line describing the selector.

See `fallout_selector`.
"""
abstract type TestSelector end

function selected_tests end
function runner_arguments end
function runner_path end
function changed_testsets end
function selector_summary end

"""
    fallout_selector(pkgdir; map="test-impact-map.toml", build=true) -> TestSelector

Selects tests with Fallout.jl's test impact map: a mutant runs only the testsets that
Fallout would select for the same edit, and a stored outcome is reused while Fallout finds
none of its testsets affected by the change since it was recorded.

Needs Fallout.jl in the environment Gremlins runs in, loaded with `using Fallout`. The
package must be the root of a git repository, and its runner script (the map's `runner`,
default `test/runtests.jl`) must run the testsets that match a regex given as its first
argument, as ReTest does (or, for a map built with `--suites`, the suite files given as
arguments). With `build`, an absent map is built statically at `HEAD`, as `fallout select`
builds one; build a coverage map with `fallout build` for the most precise selection.
"""
function fallout_selector(pkgdir::AbstractString; kwargs...)::TestSelector
    ext = Base.get_extension(@__MODULE__, :GremlinsFalloutExt)
    if ext === nothing
        throw(MutationError(
            "fallout_selector needs Fallout.jl: add it to the environment Gremlins runs in " *
                "(Pkg.add(url=\"https://github.com/ParadaCarleton/Fallout.jl\")) and load it with `using Fallout`",
        ))
    end
    return Base.invokelatest(ext.FalloutSelector, pkgdir; kwargs...)
end

# ─── Per-mutant test plan ─────────────────────────────────────────────────────

"""
    TestPlan

The tests each mutant runs: `tests[site.id]` names the testsets that can detect the mutant
(empty when none can). `runner` is the runner script relative to the package root.
"""
struct TestPlan
    selector::TestSelector
    runner::String
    tests::Dict{String, Vector{String}}
end

"""
    plan_tests(selector, pkgdir, sites) -> TestPlan

Ask `selector` for the testsets of every site, reading each source file once.
"""
function plan_tests(
    selector::TestSelector,
    pkgdir::AbstractString,
    sites::Vector{MutationSite},
)::TestPlan
    pkgdir = abspath(pkgdir)
    texts = Dict{String, String}()
    tests = Dict{String, Vector{String}}()
    for site in sites
        text = get!(texts, site.relpath) do
            read(_find_abs_path_or_throw(pkgdir, site), String)
        end
        names = selected_tests(selector, site, apply(site, text))
        tests[site.id] = sort(unique(String.(names)))
    end
    return TestPlan(selector, runner_path(selector), tests)
end

"""The testsets `plan` runs for `site` (empty when no test can detect it)."""
planned_tests(plan::TestPlan, site::MutationSite)::Vector{String} =
    get(plan.tests, site.id, String[])

"""The runner arguments that run `site`'s testsets; `nothing` without a plan (whole suite)."""
function plan_arguments(plan::Union{TestPlan, Nothing}, site::MutationSite)::Vector{String}
    plan === nothing && return String[]
    return runner_arguments(plan.selector, planned_tests(plan, site))
end

"""Whether `plan` leaves `site` without a test that can detect it."""
unreachable(plan::Union{TestPlan, Nothing}, site::MutationSite)::Bool =
    plan !== nothing && isempty(planned_tests(plan, site))

"""The test script runs use: the plan's runner, else `test_dir/test_file`."""
function plan_test_relpath(
    plan::Union{TestPlan, Nothing},
    test_dir::AbstractString,
    test_file::AbstractString,
)::String
    plan === nothing && return joinpath(test_dir, test_file)
    return plan.runner
end

"""The union of the testsets the plan runs for `sites`, sorted."""
function planned_union(plan::TestPlan, sites::Vector{MutationSite})::Vector{String}
    return sort(unique(collect(Iterators.flatten(planned_tests(plan, s) for s in sites))))
end
