# GremlinsFalloutExt — Gremlins' TestSelector over a Fallout.jl test impact map.
#
# Loaded when Fallout is loaded next to Gremlins (`using Gremlins, Fallout`).
# Construct through `Gremlins.fallout_selector(pkgdir; map, build)`.
module GremlinsFalloutExt

using Gremlins
using Gremlins: MutationError, MutationSite
using Fallout

"""
    FalloutSelector(pkgdir; map="test-impact-map.toml", build=true)

A `TestSelector` that gives a mutant the testsets Fallout selects for the edit the mutant
makes, and tells which testsets the change from an earlier commit affects.
"""
struct FalloutSelector <: Gremlins.TestSelector
    root::String
    map_path::String
    editor::Fallout.EditSelector
    all::Vector{String}          # every runnable testset: what an edit Fallout cannot place runs
    stale::Vector{String}        # testsets the change from the map's commit to now selects
    warned::Set{String}          # files already reported as outside the map's sources
end

function FalloutSelector(
    pkgdir::AbstractString;
    map::AbstractString = "test-impact-map.toml",
    build::Bool = true,
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
    editor = try
        Fallout.EditSelector(root; map = map_path, build = build)
    catch e
        throw(MutationError(
            "fallout_selector: cannot use the test impact map $map_path: $(sprint(showerror, e))",
        ))
    end
    stale = try
        Fallout.testset_names(Fallout.select_testsets(root, editor.map, editor.map.commit, ""))
    catch
        String[]
    end
    return FalloutSelector(root, map_path, editor, Fallout.testset_names(editor), stale, Set{String}())
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

"""
Rules that select a testset for any change to a `.jl` file, or for none: a static-analysis
testset, one whose map coverage is partial, one the map lacks. They say nothing about
whether this change reaches the testset, and every mutant's plan holds such testsets, so
counting them would make any edit anywhere invalidate every stored outcome. A testset
under one of these rules that the change does reach (its code was edited, it runs changed
code) is still selected by that other rule.
"""
const CHANGE_BLIND_RULES = ("static analysis:", "map status is ", "new testset, not in the map")

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
    return Set(
        name for (name, reason) in selection.reasons
        if !any(startswith(reason, rule) for rule in CHANGE_BLIND_RULES)
    )
end

function Gremlins.selector_summary(selector::FalloutSelector)::String
    map = selector.editor.map
    line = "Fallout map $(relpath(selector.map_path, selector.root)) at $(first(map.commit, 12)): " *
        "$(length(selector.all)) testsets, runner $(map.runner)"
    if !isempty(selector.stale)
        line *= "; $(length(selector.stale)) testsets run code changed since the map's commit " *
            "(their coverage may be out of date: rebuild the map with `fallout build`)"
    end
    return line
end

end # module GremlinsFalloutExt
