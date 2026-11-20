# frozen_string_literal: true
#
# Run the shared corpus against ref/ruby/whoami.rb.
#
# SPDX-License-Identifier: MIT
#
# Same job and same output shape as every other runner here, so results can be
# compared line for line. The corpus is the authority; a runner that disagrees
# with it is reporting a defect in its implementation.

require_relative '../ref/ruby/whoami'

HERE = File.dirname(File.expand_path(__FILE__))
CORPUS = File.join(HERE, 'corpus')

# Map this implementation's wording to the corpus's canonical token. Each
# language keeps its own phrasing; only the token has to agree.
TOKENS = [
  ['empty', 'empty'],
  ['preamble', 'preamble'],
  ['schema', 'schema'],
  ['special', 'special'],
  ['exceeded', 'bounds']
].freeze

def canonical(message)
  TOKENS.each { |needle, token| return token if message.include?(needle) }
  "unmapped:#{message}"
end

def load_expect(path)
  out = {}
  File.read(path, mode: 'rb').split("\n").each do |raw|
    next if raw.empty? || raw.start_with?('#')

    eq = raw.index('=') # FIRST equals: a label may contain a space
    next if eq.nil?

    out[raw[0, eq]] = raw[(eq + 1)..].to_s.chomp("\r")
  end
  out
end

def check(name)
  bytes = File.read(File.join(CORPUS, "#{name}.report"), mode: 'rb')
  expect = load_expect(File.join(CORPUS, "#{name}.expect"))
  problems = []
  report = nil
  want_error = expect['status'] == 'error'

  begin
    report = Whoami.parse(bytes)
    problems << 'read succeeded, but this case exists to be refused' if want_error
  rescue Whoami::Error => e
    got = canonical(e.message)
    if !want_error
      problems << "raised '#{e.message}' but the case expects a successful read"
    elsif expect.key?('error') && got != expect['error']
      problems << "error token '#{got}', corpus says '#{expect['error']}'"
    end
  end

  return problems if report.nil?

  expect.keys.sort.each do |key|
    want = expect[key]
    next if %w[status error].include?(key)

    if key.start_with?('field.')
      label = key[6..]
      got = report[label]
      problems << "field '#{label}' is #{got.inspect}, corpus says #{want.inspect}" if got != want
    elsif key == 'major' && report.major.to_s != want
      problems << "major #{report.major}, corpus says #{want}"
    elsif key == 'revision' && report.revision.to_s != want
      problems << "revision #{report.revision}, corpus says #{want}"
    elsif key == 'speaks'
      got = report.speaks.join(' ')
      problems << "speaks '#{got}', corpus says '#{want}'" if got != want
    elsif key == 'refusal'
      got = report.refusal ? 'true' : 'false'
      problems << "refusal #{got}, corpus says #{want}" if got != want
    elsif key == 'blocks' && report.special_blocks.to_s != want
      problems << "blocks #{report.special_blocks}, corpus says #{want}"
    end
  end
  problems
end

names = File.read(File.join(CORPUS, 'INDEX'), mode: 'rb')
            .split("\n").map(&:strip).reject(&:empty?)
bad = 0
names.each do |name|
  problems = check(name)
  bad += 1 unless problems.empty?
  puts format('  %-4s %s', problems.empty? ? 'ok' : 'FAIL', name)
  problems.each { |p| puts "        #{p}" }
end
puts
puts format('  ruby: %d cases, %d failed', names.length, bad)
exit(bad.zero? ? 0 : 1)
