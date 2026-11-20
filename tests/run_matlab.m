function run_matlab()
%RUN_MATLAB Run the shared corpus against ref/matlab/whoami_parse.m.
%
%   SPDX-License-Identifier: MIT
%
%   Same job and same output shape as every other runner here, so results can
%   be compared line for line. The corpus is the authority; a runner that
%   disagrees with it is reporting a defect in its implementation.
%
%   Classification is BY ERROR IDENTIFIER, never by message text. A message is
%   for a human and may be reworded; an identifier is the contract.

here   = fileparts(mfilename('fullpath'));
repo   = fileparts(here);
corpus = fullfile(here, 'corpus');
addpath(fullfile(repo, 'ref', 'matlab'));

names = local_read_index(fullfile(corpus, 'INDEX'));
bad = 0;

for n = 1:numel(names)
    name = names{n};
    problems = local_check(corpus, name);
    if ~isempty(problems)
        bad = bad + 1;
        status = 'FAIL';
    else
        status = 'ok';
    end
    fprintf('  %-4s %s\n', status, name);
    for p = 1:numel(problems)
        fprintf('        %s\n', problems{p});
    end
end

fprintf('\n  matlab: %d cases, %d failed\n', numel(names), bad);
if bad > 0
    exit(1);
end
exit(0);
end


function problems = local_check(corpus, name)
problems = {};
raw = local_read_bytes(fullfile(corpus, [name '.report']));
expect = local_read_expect(fullfile(corpus, [name '.expect']));
report = [];
wantError = isKey(expect, 'status') && strcmp(expect('status'), 'error');

try
    report = whoami_parse(raw);
    if wantError
        problems{end+1} = 'read succeeded, but this case exists to be refused';
    end
catch err
    % 'whoami:bounds' -> 'bounds'. Identifier, not text.
    parts = strsplit(err.identifier, ':');
    got = parts{end};
    if ~wantError
        problems{end+1} = sprintf( ...
            'threw ''%s'' but the case expects a successful read', err.identifier);
    elseif isKey(expect, 'error') && ~strcmp(got, expect('error'))
        problems{end+1} = sprintf('error token ''%s'', corpus says ''%s''', ...
                                  got, expect('error'));
    end
end

if isempty(report)
    return;
end

keys_ = sort(keys(expect));
for k = 1:numel(keys_)
    key = keys_{k};
    want = expect(key);
    if strcmp(key, 'status') || strcmp(key, 'error')
        continue;
    end
    if startsWith(key, 'field.')
        label = key(7:end);
        if isKey(report.fields, label)
            got = report.fields(label);
        else
            got = '<absent>';
        end
        if ~strcmp(got, want)
            problems{end+1} = sprintf('field ''%s'' is ''%s'', corpus says ''%s''', ...
                                      label, got, want); %#ok<AGROW>
        end
    elseif strcmp(key, 'major')
        got = sprintf('%d', report.major);
        if ~strcmp(got, want)
            problems{end+1} = sprintf('major %s, corpus says %s', got, want); %#ok<AGROW>
        end
    elseif strcmp(key, 'revision')
        got = sprintf('%d', report.revision);
        if ~strcmp(got, want)
            problems{end+1} = sprintf('revision %s, corpus says %s', got, want); %#ok<AGROW>
        end
    elseif strcmp(key, 'speaks')
        got = strtrim(sprintf('%d ', report.speaks));
        if ~strcmp(got, want)
            problems{end+1} = sprintf('speaks ''%s'', corpus says ''%s''', got, want); %#ok<AGROW>
        end
    elseif strcmp(key, 'refusal')
        if report.refusal
            got = 'true';
        else
            got = 'false';
        end
        if ~strcmp(got, want)
            problems{end+1} = sprintf('refusal %s, corpus says %s', got, want); %#ok<AGROW>
        end
    elseif strcmp(key, 'blocks')
        got = sprintf('%d', report.special_blocks);
        if ~strcmp(got, want)
            problems{end+1} = sprintf('blocks %s, corpus says %s', got, want); %#ok<AGROW>
        end
    end
end
end


function bytes = local_read_bytes(path)
%LOCAL_READ_BYTES Raw bytes. fileread() would apply an encoding and normalize
%line endings, repairing the very malformations the corpus is testing.
fid = fopen(path, 'r');
if fid < 0
    error('run_matlab:io', 'cannot read %s', path);
end
cleanup = onCleanup(@() fclose(fid));
bytes = uint8(fread(fid, inf, 'uint8=>uint8'))';
end


function names = local_read_index(path)
text = char(local_read_bytes(path));
parts = strsplit(text, newline);
names = {};
for k = 1:numel(parts)
    piece = strtrim(parts{k});
    if ~isempty(piece)
        names{end+1} = piece; %#ok<AGROW>
    end
end
end


function map = local_read_expect(path)
map = containers.Map('KeyType', 'char', 'ValueType', 'char');
text = char(local_read_bytes(path));
parts = strsplit(text, newline);
for k = 1:numel(parts)
    line = parts{k};
    if isempty(strtrim(line)) || line(1) == '#'
        continue;
    end
    eq = find(line == '=', 1, 'first');   % FIRST equals: a label may hold a space
    if isempty(eq)
        continue;
    end
    key = line(1:eq-1);
    value = line(eq+1:end);
    if ~isempty(value) && value(end) == sprintf('\r')
        value = value(1:end-1);
    end
    map(key) = value;
end
end
