function report = whoami_parse(text)
%WHOAMI_PARSE Read a whoami report.
%
%   SPDX-License-Identifier: MIT
%
%   REPORT = WHOAMI_PARSE(TEXT) parses TEXT (a char row vector, a string, or a
%   uint8 row vector of raw bytes) and returns a struct describing it.
%
%   A REPORT ARRIVES FROM SOMETHING NOT YET IDENTIFIED. That is what it is for.
%   Every number in it is therefore input, not instruction -- including the
%   counts that say how far to read. SPEC.md "Reading one safely" is the
%   contract this file implements: the format tells a reader how far to read,
%   and the reader decides how far it is willing to. Both halves are required.
%   A length you trust without a bound is not a safety feature, it is an
%   instruction.
%
%   NO REGULAR EXPRESSIONS ON UNTRUSTED INPUT, matching every other reference
%   implementation. A parser whose safety rests on a regex is one backtracking
%   pattern away from the denial of service the bounds exist to prevent.
%
%   FIELDS ARE RETURNED IN A containers.Map, NOT A STRUCT. A label may contain
%   a space -- 'front end' is a real one on this bench -- and that is not a
%   valid MATLAB field name. A struct would force either mangling the label or
%   dropping the field, and both are silent corruption.
%
%   Errors carry a stable identifier, so a caller classifies by identifier and
%   never by message text:
%       whoami:empty  whoami:preamble  whoami:schema  whoami:special
%       whoami:bounds
%
%   See also WHOAMI_EMIT.

GRID         = 11;    % columns 1-11 are the label; the value starts at 12
MAX_LINES    = 500;   % total, so a looping device is a failed read
MAX_SPECIAL  = 100;   % lines skipped for one block
MAX_SPEAKS   = 16;    % majors recorded from the speaks line
MAX_FIELDS   = 64;    % fields recorded; the rest are counted only
PREAMBLE_MAX = 512;   % bytes before the preamble must have landed

if isa(text, 'uint8')
    % char() of uint8 never fails and never reinterprets a byte, so a report
    % carrying something unexpected is READ rather than refused.
    text = char(text(:)');
elseif isstring(text)
    text = char(text);
end
if isempty(text)
    error('whoami:empty', 'empty report');
end
text = reshape(text, 1, []);

report = struct( ...
    'major', 0, 'revision', 0, 'speaks', [], 'speaks_truncated', false, ...
    'fields', containers.Map('KeyType', 'char', 'ValueType', 'char'), ...
    'labels', {{}}, 'fields_seen', 0, 'special_blocks', 0, ...
    'lines_read', 0, 'refusal', false, 'schema', '');

% BOUND THE PREAMBLE READ. A device that never sends a newline must not be able
% to hang a reader, and the preamble's whole value is that the decision is
% cheap -- so cap the bytes before it has to have landed.
if numel(text) > PREAMBLE_MAX
    head = text(1:PREAMBLE_MAX);
    if sum(head == newline) < 2
        error('whoami:bounds', ...
              'report exceeded its bound (no newline within the first %d bytes)', ...
              PREAMBLE_MAX);
    end
end

lines = local_split_lines(text);
if numel(lines) < 2
    error('whoami:preamble', 'missing or malformed preamble');
end

[label, value] = local_split(lines{1}, GRID);
if ~strcmp(label, 'schema')
    error('whoami:preamble', 'missing or malformed preamble');
end
report.lines_read = 1;
[report.major, report.revision] = local_parse_schema(value);
report.schema = sprintf('%d.%04d', report.major, report.revision);

[label, value] = local_split(lines{2}, GRID);
if ~strcmp(label, 'speaks')
    error('whoami:preamble', 'missing or malformed preamble');
end
report.lines_read = 2;
[report.speaks, report.speaks_truncated] = local_parse_speaks(value, MAX_SPEAKS);

% Preamble and nothing else is a REFUSAL, and a successful read: the device
% answered with the frozen preamble alone, which is what one that cannot speak
% the requested major is required to do.
rest = lines(3:end);
if all(cellfun(@(s) isempty(strtrim(s)), rest))
    report.refusal = true;
    return;
end

index = 3;
while index <= numel(lines)
    line = lines{index};
    index = index + 1;
    report.lines_read = report.lines_read + 1;
    if report.lines_read > MAX_LINES
        error('whoami:bounds', 'report exceeded its line bound');
    end
    if isempty(strtrim(line))
        continue;
    end
    [label, value] = local_split(line, GRID);
    if isempty(label)
        continue;
    end

    if strcmp(label, 'special')
        % 'special <count> <tag>' -- the count only. The tag is deliberately
        % not interpreted: not knowing it is the expected case, not an error.
        parts = strsplit(strtrim(value));
        count = local_to_int(parts{1});
        % BOUND THE COUNT. An unbounded count supplied by the far end is a
        % request to read forever. Past the cap it is a malformed report, not
        % an instruction to obey.
        if isnan(count) || count > MAX_SPECIAL
            error('whoami:special', 'special block count past the bound');
        end
        for k = 1:count
            if index > numel(lines)
                break;   % truncated; nothing left to skip
            end
            index = index + 1;
            report.lines_read = report.lines_read + 1;
            if report.lines_read > MAX_LINES
                error('whoami:bounds', 'report exceeded its line bound');
            end
        end
        report.special_blocks = report.special_blocks + 1;
        continue;
    end

    report.fields_seen = report.fields_seen + 1;
    % Past the cap a field is counted but not stored, so fields_seen ~=
    % numel(labels) tells a caller it did not see everything -- rather than the
    % report looking complete. First match wins; a duplicate label is a
    % conformance question, not a reading one.
    if numel(report.labels) < MAX_FIELDS && ~isKey(report.fields, label)
        report.fields(label) = value;
        report.labels{end+1} = label; %#ok<AGROW>
    end
end
end


function lines = local_split_lines(text)
%LOCAL_SPLIT_LINES Split on LF and drop a trailing CR. Serial consoles emit
%CRLF; a reader that only accepts LF fails on real hardware while passing every
%test written on a workstation.
parts = strsplit(text, newline, 'CollapseDelimiters', false);
lines = cell(1, numel(parts));
for k = 1:numel(parts)
    piece = parts{k};
    if ~isempty(piece) && piece(end) == sprintf('\r')
        piece = piece(1:end-1);
    end
    lines{k} = piece;
end
end


function [label, value] = local_split(line, grid)
%LOCAL_SPLIT Label and value BY SLICE, NOT BY SEARCHING FOR WHITESPACE.
%
%   Columns 1..GRID are the label, right-trimmed; the rest is the value,
%   left-trimmed. That fixed width is the whole reason the grid exists: it lets
%   a label contain a space -- 'front end' -- with no escaping and no ambiguity
%   about where it ends. Splitting on the first space instead reads that label
%   as 'front' and silently moves 'end' into the value: a corrupted read that
%   looks like a successful one.
label = '';
value = '';
if isempty(strtrim(line))
    return;
end
cut = min(numel(line), grid);
label = deblank(line(1:cut));
if isempty(label)
    return;
end
if numel(line) > grid
    value = strip_leading(line(grid+1:end));
end
end


function out = strip_leading(str)
idx = find(str ~= ' ' & str ~= sprintf('\t'), 1, 'first');
if isempty(idx)
    out = '';
else
    out = str(idx:end);
end
end


function [major, revision] = local_parse_schema(value)
dot = find(value == '.', 1, 'first');
if isempty(dot) || dot == 1 || dot == numel(value)
    error('whoami:schema', 'schema value not <major>.<4 digits>');
end
majorText = value(1:dot-1);
revText   = value(dot+1:end);
% FOUR DIGITS, zero-padded, always. Fixed width is what makes 1.0012 and
% 1.0002 compare correctly as text, and a reader that accepts 1.12 is
% accepting a report no conformant emitter produces.
if numel(revText) ~= 4
    error('whoami:schema', 'schema value not <major>.<4 digits>');
end
major = local_to_int(majorText);
revision = local_to_int(revText);
if isnan(major) || isnan(revision)
    error('whoami:schema', 'schema value not <major>.<4 digits>');
end
end


function [speaks, truncated] = local_parse_speaks(value, maxSpeaks)
speaks = [];
truncated = false;
if isempty(strtrim(value))
    return;
end
for part = strsplit(strtrim(value))
    major = local_to_int(part{1});
    if isnan(major)
        continue;   % unreadable entry; the rest may be fine
    end
    if numel(speaks) < maxSpeaks
        speaks(end+1) = major; %#ok<AGROW>
    else
        truncated = true;
    end
end
end


function value = local_to_int(str)
%LOCAL_TO_INT Non-negative decimal, or NaN.
%
%   Length-capped BEFORE conversion, because a count that wrapped is a count
%   the far end chose, and obeying it is the failure this refuses. str2double
%   is NOT used: it accepts '1e9', ' 12 ', '-1' and 'Inf', every one of which
%   is a number the far end would like this reader to believe.
value = NaN;
if isempty(str) || numel(str) > 9
    return;
end
if any(str < '0' | str > '9')
    return;
end
value = 0;
for k = 1:numel(str)
    value = value * 10 + double(str(k) - '0');
end
end
