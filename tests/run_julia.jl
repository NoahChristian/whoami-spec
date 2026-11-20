# Run the shared corpus against ref/julia/Whoami.jl.
#
# SPDX-License-Identifier: MIT
#
# Same job and same output shape as every other runner here, so results can be
# compared line for line. The corpus is the authority; a runner that disagrees
# with it is reporting a defect in its implementation.
#
# Classification is BY ERROR TOKEN, never by message text: a message is for a
# human and may be reworded, while the token is the contract.

const HERE = dirname(abspath(@__FILE__))
const REPO = dirname(HERE)
const CORPUS = length(ARGS) > 0 ? ARGS[1] : joinpath(HERE, "corpus")

include(joinpath(REPO, "ref", "julia", "Whoami.jl"))
using .Whoami

function load_expect(path)
    out = Dict{String,String}()
    for raw in eachline(path)
        (isempty(raw) || startswith(raw, "#")) && continue
        eq = findfirst(==('='), raw)   # FIRST equals
        eq === nothing && continue
        out[raw[1:(eq - 1)]] = raw[(eq + 1):end]
    end
    return out
end

function check(name)
    problems = String[]
    # read() gives raw bytes; readlines would normalize line endings and
    # repair the very malformations under test.
    bytes = read(joinpath(CORPUS, name * ".report"))
    expect = load_expect(joinpath(CORPUS, name * ".expect"))
    want_error = get(expect, "status", "ok") == "error"

    local report
    got_report = false
    try
        report = Whoami.parse_report(bytes)
        got_report = true
        want_error && push!(problems,
            "read succeeded, but this case exists to be refused")
    catch err
        err isa Whoami.WhoamiError || rethrow()
        got = String(err.token)
        if !want_error
            push!(problems, "threw $got but the case expects a successful read")
        elseif haskey(expect, "error") && got != expect["error"]
            push!(problems, "error token '$got', corpus says '$(expect["error"])'")
        end
    end

    got_report || return problems

    for key in sort(collect(keys(expect)))
        want = expect[key]
        (key == "status" || key == "error") && continue
        if startswith(key, "field.")
            label = key[7:end]
            value = Whoami.get_field(report, label)
            if value === nothing
                push!(problems, "field '$label' absent, corpus says '$want'")
            elseif value != want
                push!(problems, "field '$label' is '$value', corpus says '$want'")
            end
            continue
        end
        got = if key == "major"
            string(report.major)
        elseif key == "revision"
            string(report.revision)
        elseif key == "refusal"
            report.refusal ? "true" : "false"
        elseif key == "blocks"
            string(report.special_blocks)
        elseif key == "speaks"
            join(report.speaks, " ")
        else
            continue
        end
        got == want || push!(problems, "$key is '$got', corpus says '$want'")
    end
    return problems
end

names = filter(!isempty, strip.(readlines(joinpath(CORPUS, "INDEX"))))
bad = 0
for name in names
    problems = check(name)
    isempty(problems) || (bad += 1)
    println("  ", rpad(isempty(problems) ? "ok" : "FAIL", 4), " ", name)
    for problem in problems
        println("        ", problem)
    end
end
println()
println("  julia: $(length(names)) cases, $bad failed")
exit(bad > 0 ? 1 : 0)
