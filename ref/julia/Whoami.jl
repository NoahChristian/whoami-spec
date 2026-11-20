"""
    Whoami

Read a whoami report.

SPDX-License-Identifier: MIT

A REPORT ARRIVES FROM SOMETHING NOT YET IDENTIFIED. That is what it is for.
Every number in it is therefore input, not instruction -- including the counts
that say how far to read. SPEC.md "Reading one safely" is the contract this
module implements: the format tells a reader how far to read, and the reader
decides how far it is willing to. Both halves are required. A length you trust
without a bound is not a safety feature, it is an instruction.

NO REGULAR EXPRESSIONS ON UNTRUSTED INPUT, matching every other reference
implementation. Index arithmetic and fixed-string comparison only.

BYTES, NOT CHARACTERS. Julia indexes strings by byte offset and throws on a
non-boundary index, so a report carrying an unexpected byte could make a
careless reader raise `StringIndexError` instead of reporting a field problem.
Everything here works on a `Vector{UInt8}` and converts to `String` only once a
slice is known to be whole, which is also what makes "columns 1 to 11" mean the
same thing it means in the C implementation.

NOT A VALIDATOR. It answers "what does this say", bounded and without trusting
it. Conformance is a separate, stricter question.
"""
module Whoami

export WhoamiError, Report, parse_report, get_field, speaks_major

const GRID = 11          # columns 1-11 are the label; the value starts at 12

# Bounds. Each exists so a hostile or broken far end cannot make a reader work
# harder than the reader chose to.
const MAX_LINES    = 500 # total, so a looping device is a failed read
const MAX_SPECIAL  = 100 # lines skipped for one block
const MAX_SPEAKS   = 16  # majors recorded from the speaks line
const MAX_FIELDS   = 64  # fields recorded; the rest are counted only
const PREAMBLE_MAX = 512 # bytes before the preamble must have landed

"""
    WhoamiError(token, msg)

`token` is one of `:empty`, `:preamble`, `:schema`, `:special`, `:bounds`.
Callers classify on the token, never on the message: a message is for a human
and may be reworded.
"""
struct WhoamiError <: Exception
    token::Symbol
    msg::String
end

Base.showerror(io::IO, e::WhoamiError) = print(io, "whoami[", e.token, "]: ", e.msg)

mutable struct Report
    major::Int
    revision::Int
    speaks::Vector{Int}
    speaks_truncated::Bool
    labels::Vector{String}      # order preserved
    fields::Dict{String,String}
    fields_seen::Int            # including any past MAX_FIELDS
    special_blocks::Int
    lines_read::Int
    # A REFUSAL IS A SUCCESSFUL READ, not an error: the device answered with
    # the frozen preamble alone, which is what one that cannot speak the
    # requested major is required to do, and is the one answer a reader of ANY
    # major is guaranteed to understand.
    refusal::Bool
end

Report() = Report(0, 0, Int[], false, String[], Dict{String,String}(), 0, 0, 0, false)

schema_string(r::Report) = string(r.major, ".", lpad(r.revision, 4, '0'))

"""Field lookup. `nothing` when absent, never `""` -- an absent field and a
field whose value is empty are different facts."""
get_field(r::Report, label::AbstractString) = get(r.fields, String(label), nothing)

speaks_major(r::Report, major::Integer) = major in r.speaks

"""Non-negative decimal, or `nothing`.

Length-capped BEFORE conversion, because a count that wrapped is a count the
far end chose, and obeying it is the failure this refuses. `Base.parse` is not
used on its own: it accepts a leading `+` and whitespace, and the point here is
to accept exactly one shape."""
function to_int(bytes::AbstractVector{UInt8})
    (isempty(bytes) || length(bytes) > 9) && return nothing
    value = 0
    for b in bytes
        (b < UInt8('0') || b > UInt8('9')) && return nothing
        value = value * 10 + Int(b - UInt8('0'))
    end
    return value
end

to_int(s::AbstractString) = to_int(Vector{UInt8}(codeunits(s)))

isblank(b::UInt8) = b == UInt8(' ') || b == UInt8('\t')

"""
Label and value, BY SLICE AND NOT BY SPLITTING ON WHITESPACE.

Columns 1..GRID are the label, right-trimmed; the rest is the value,
left-trimmed. That fixed width is the whole reason the grid exists: it lets a
label contain a space -- `front end` -- with no escaping and no ambiguity about
where it ends. Splitting on the first space instead reads that label as `front`
and silently moves `end` into the value: a corrupted read that looks like a
successful one.
"""
function split_line(line::AbstractVector{UInt8})
    all(b -> isblank(b) || b == UInt8('\r'), line) && return (nothing, "")
    stop = min(GRID, length(line))
    while stop > 0 && isblank(line[stop])
        stop -= 1
    end
    stop == 0 && return (nothing, "")
    label = String(copy(line[1:stop]))
    value = ""
    if length(line) > GRID
        start = GRID + 1
        while start <= length(line) && isblank(line[start])
            start += 1
        end
        start <= length(line) && (value = String(copy(line[start:end])))
    end
    return (label, value)
end

function parse_schema!(report::Report, value::AbstractString)
    bad() = throw(WhoamiError(:schema, "schema value not <major>.<4 digits>"))
    bytes = Vector{UInt8}(codeunits(value))
    dot = findfirst(==(UInt8('.')), bytes)
    (dot === nothing || dot == 1 || dot == length(bytes)) && bad()
    revision_bytes = bytes[(dot + 1):end]
    # FOUR DIGITS, zero-padded, always. Fixed width is what makes 1.0012 and
    # 1.0002 compare correctly as text, and a reader that accepts 1.12 is
    # accepting a report no conformant emitter produces.
    length(revision_bytes) == 4 || bad()
    major = to_int(bytes[1:(dot - 1)])
    revision = to_int(revision_bytes)
    (major === nothing || revision === nothing) && bad()
    report.major = major
    report.revision = revision
    return nothing
end

function parse_speaks!(report::Report, value::AbstractString)
    for word in split(value)
        isempty(word) && continue
        major = to_int(word)
        major === nothing && continue   # unreadable entry; the rest may be fine
        if length(report.speaks) < MAX_SPEAKS
            push!(report.speaks, major)
        else
            report.speaks_truncated = true
        end
    end
    return nothing
end

"""
    parse_report(data) -> Report

Parse a report. `data` may be a `String` or a `Vector{UInt8}`; lines may end LF
or CRLF. Throws `WhoamiError`.
"""
function parse_report(data)
    report = Report()
    bytes = data isa AbstractString ? Vector{UInt8}(codeunits(data)) : Vector{UInt8}(data)
    isempty(bytes) && throw(WhoamiError(:empty, "empty report"))

    # BOUND THE PREAMBLE READ. A device that never sends a newline must not be
    # able to hang a reader, and the preamble's whole value is that the
    # decision is cheap -- so cap the bytes before it has to have landed.
    if length(bytes) > PREAMBLE_MAX
        newlines = count(==(UInt8('\n')), @view bytes[1:PREAMBLE_MAX])
        newlines < 2 && throw(WhoamiError(:bounds,
            "report exceeded its bound (no newline within the first $PREAMBLE_MAX bytes)"))
    end

    lines = Vector{Vector{UInt8}}()
    start = 1
    for i in 1:length(bytes)
        if bytes[i] == UInt8('\n')
            stop = i - 1
            stop >= start && bytes[stop] == UInt8('\r') && (stop -= 1)
            push!(lines, bytes[start:stop])
            start = i + 1
        end
    end
    if start <= length(bytes)
        stop = length(bytes)
        bytes[stop] == UInt8('\r') && (stop -= 1)
        push!(lines, bytes[start:stop])
    end
    length(lines) < 2 && throw(WhoamiError(:preamble, "missing or malformed preamble"))

    label, value = split_line(lines[1])
    label == "schema" || throw(WhoamiError(:preamble, "missing or malformed preamble"))
    report.lines_read += 1
    parse_schema!(report, value)

    label, value = split_line(lines[2])
    label == "speaks" || throw(WhoamiError(:preamble, "missing or malformed preamble"))
    report.lines_read += 1
    parse_speaks!(report, value)

    rest = @view lines[3:end]
    if all(l -> all(b -> isblank(b) || b == UInt8('\r'), l), rest)
        report.refusal = true
        return report
    end

    index = 1
    while index <= length(rest)
        line = rest[index]
        index += 1
        report.lines_read += 1
        report.lines_read > MAX_LINES &&
            throw(WhoamiError(:bounds, "report exceeded its line bound"))
        all(b -> isblank(b) || b == UInt8('\r'), line) && continue

        lab, val = split_line(line)
        lab === nothing && continue

        if lab == "special"
            # `special <count> <tag>` -- the count only. The tag is
            # deliberately not interpreted: not knowing it is the expected
            # case, not an error.
            words = split(val)
            count = isempty(words) ? nothing : to_int(words[1])
            # BOUND THE COUNT. An unbounded count supplied by the far end is a
            # request to read forever. Past the cap it is a malformed report,
            # not an instruction to obey.
            (count === nothing || count > MAX_SPECIAL) &&
                throw(WhoamiError(:special, "special block count past the bound"))
            skip = min(count, length(rest) - index + 1)  # truncated: skip what exists
            index += skip
            report.lines_read += skip
            report.lines_read > MAX_LINES &&
                throw(WhoamiError(:bounds, "report exceeded its line bound"))
            report.special_blocks += 1
            continue
        end

        report.fields_seen += 1
        # Past the cap a field is counted but not stored, so fields_seen !=
        # length(labels) tells a caller it did not see everything. First match
        # wins; a duplicate label is a conformance question.
        if length(report.labels) < MAX_FIELDS && !haskey(report.fields, lab)
            report.fields[lab] = val
            push!(report.labels, lab)
        end
    end
    return report
end

end # module
