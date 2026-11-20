# frozen_string_literal: true
#
# whoami.rb - read a whoami report.
#
# SPDX-License-Identifier: MIT
#
# A REPORT ARRIVES FROM SOMETHING NOT YET IDENTIFIED. That is what it is for.
# Every number in it is therefore input, not instruction -- including the counts
# that say how far to read. SPEC.md "Reading one safely" is the contract this
# file implements, and the shape of all of it is: the format tells a reader how
# far to read, and the reader decides how far it is willing to. Both halves are
# required. A length you trust without a bound is not a safety feature, it is an
# instruction.
#
# NO REGULAR EXPRESSIONS ON UNTRUSTED INPUT. String operations only -- the same
# choice the Python and C implementations make, for the same reason: a parser
# whose safety rests on a regex is one backtracking pattern away from the denial
# of service the bounds exist to prevent. It also keeps all four
# implementations behaving identically, which is the point of there being a
# reference at all.
#
# NOT A VALIDATOR. It answers "what does this say", bounded and without trusting
# it. Whether a report is CONFORMANT is a separate, stricter question that
# tools/whoami_check.py answers.

module Whoami
  GRID = 11           # columns 1-11 are the label; the value starts at 12

  # Bounds. Each exists so a hostile or broken far end cannot make a reader work
  # harder than the reader chose to.
  MAX_LINES    = 500  # total, so a looping device is a failed read
  MAX_SPECIAL  = 100  # lines skipped for one block
  MAX_SPEAKS   = 16   # majors recorded from the speaks line
  MAX_FIELDS   = 64   # fields recorded; the rest are counted only
  PREAMBLE_MAX = 512  # bytes before the preamble must have landed

  # A report that could not be read within the bounds this reader set.
  class Error < StandardError
    # Filled in as far as parsing got, so a caller can say what it DID
    # understand -- which for an unidentified device is usually more useful
    # than the error alone.
    attr_reader :report

    def initialize(message, report = nil)
      super(message)
      @report = report
    end
  end

  # What a report says. Values are text; interpretation is the caller's.
  class Report
    attr_accessor :major, :revision, :speaks, :speaks_truncated,
                  :fields, :fields_seen, :special_blocks, :lines_read, :refusal

    def initialize
      @major = 0
      @revision = 0
      @speaks = []
      @speaks_truncated = false
      @fields = []        # [label, value] pairs, in order
      @fields_seen = 0    # including any past MAX_FIELDS
      @special_blocks = 0
      @lines_read = 0
      # A REFUSAL IS A SUCCESSFUL READ, not an error. The device answered with
      # the preamble alone, which is what SPEC.md requires of one that cannot
      # speak the requested major -- and is the one answer a reader of ANY
      # major is guaranteed to understand.
      @refusal = false
    end

    # First match wins. A duplicate label is a conformance question, not a
    # reading one.
    def [](label)
      pair = @fields.find { |name, _| name == label }
      pair && pair[1]
    end

    def key?(label)
      !self[label].nil?
    end

    def speaks_major?(major)
      @speaks.include?(major)
    end

    def schema
      format('%d.%04d', @major, @revision)
    end

    def to_s
      "#<Whoami::Report schema=#{schema} speaks=#{@speaks.inspect} " \
        "fields=#{@fields.length}#{@refusal ? ' REFUSAL' : ''}>"
    end
  end

  module_function

  def digits?(str)
    return false if str.nil? || str.empty?

    str.each_char { |ch| return false if ch < '0' || ch > '9' }
    true
  end

  # Non-negative decimal, or nil. Length-capped BEFORE conversion, because a
  # count that wrapped is a count the far end chose, and obeying it is the
  # failure this refuses.
  def to_int(str)
    return nil unless digits?(str) && str.length <= 9

    str.to_i
  end

  # Label and value, BY SLICE AND NOT BY SPLITTING ON WHITESPACE.
  #
  # Columns 1-11 are the label, right-trimmed; column 12 onward is the value,
  # left-trimmed. That fixed width is the whole reason the grid exists: it lets
  # a label contain a space -- `front end` -- with no escaping and no ambiguity
  # about where it ends. Splitting on the first space instead reads that label
  # as `front` and silently moves `end` into the value, which is a corrupted
  # read that looks like a successful one.
  def split_line(line)
    return [nil, nil] if line.nil? || line.strip.empty?

    label = line[0, GRID].to_s.rstrip
    return [nil, nil] if label.empty?

    value = line.length > GRID ? line[GRID..].lstrip : ''
    [label, value]
  end

  def parse_schema(value, report)
    dot = value.index('.')
    raise Error.new('schema value not <major>.<4 digits>', report) if dot.nil? || dot.zero?

    major = value[0, dot]
    revision = value[(dot + 1)..].to_s
    # FOUR DIGITS, zero-padded, always. Fixed width is what makes "1.0012" and
    # "1.0002" compare correctly as text, and a reader that accepts "1.12" is
    # accepting a report no conformant emitter produces.
    unless revision.length == 4
      raise Error.new('schema value not <major>.<4 digits>', report)
    end

    m = to_int(major)
    r = to_int(revision)
    raise Error.new('schema value not <major>.<4 digits>', report) if m.nil? || r.nil?

    report.major = m
    report.revision = r
  end

  def parse_speaks(value, report)
    value.split.each do |word|
      major = to_int(word)
      next if major.nil? # unreadable entry; the rest may be fine

      if report.speaks.length < MAX_SPEAKS
        report.speaks << major
      else
        report.speaks_truncated = true
      end
    end
  end

  # Parse a report. Returns a Report, or raises Whoami::Error.
  # Lines may end LF or CRLF.
  def parse(text)
    report = Report.new
    raise Error.new('empty', report) if text.nil? || text.empty?

    # Binary encoding never fails and never reinterprets a byte, so a report
    # carrying something unexpected is READ rather than refused. An encoding
    # error here would turn a field problem into a total read failure.
    text = text.dup.force_encoding(Encoding::BINARY)

    # BOUND THE PREAMBLE READ. A device that never sends a newline must not be
    # able to hang a reader, and the preamble's whole value is that the
    # decision is cheap -- so cap the bytes before it has to have landed.
    if text.length > PREAMBLE_MAX && text[0, PREAMBLE_MAX].count("\n") < 2
      raise Error.new('report exceeded its bound', report)
    end

    lines = text.split("\n", -1).map { |l| l.end_with?("\r") ? l[0..-2] : l }
    index = 0
    take = lambda do
      return nil if index >= lines.length

      line = lines[index]
      index += 1
      line
    end

    label, value = split_line(take.call)
    raise Error.new('missing or malformed preamble', report) if label != 'schema'

    report.lines_read += 1
    parse_schema(value, report)

    label, value = split_line(take.call)
    raise Error.new('missing or malformed preamble', report) if label != 'speaks'

    report.lines_read += 1
    parse_speaks(value, report)

    # Preamble and nothing else is a refusal, and a successful read.
    if lines[index..].to_a.all? { |l| l.strip.empty? }
      report.refusal = true
      return report
    end

    while (line = take.call)
      report.lines_read += 1
      raise Error.new('report exceeded its bound', report) if report.lines_read > MAX_LINES
      next if line.strip.empty?

      label, value = split_line(line)
      next if label.nil?

      if label == 'special'
        # `special <count> <tag>` -- the count only. The tag is deliberately
        # not interpreted: not knowing it is the expected case, not an error.
        count = to_int(value.split.first.to_s)
        # BOUND THE COUNT. Anything past the cap is a malformed report rather
        # than an instruction to obey. An unbounded count from the far end is a
        # request to read forever -- the same guard the RS485 link on this
        # bench keeps as LINK_MAX_LEN, where a length past a sane bound is not
        # a long frame, it is noise that happened to contain a sync pattern.
        if count.nil? || count > MAX_SPECIAL
          raise Error.new('special block count past the bound', report)
        end

        count.times do
          break if take.call.nil? # truncated; nothing left to skip

          report.lines_read += 1
          raise Error.new('report exceeded its bound', report) if report.lines_read > MAX_LINES
        end
        report.special_blocks += 1
        next
      end

      report.fields_seen += 1
      # Past the cap a field is counted but not stored, so fields_seen !=
      # fields.length tells a caller it did not see everything -- rather than
      # the report looking complete.
      report.fields << [label, value] if report.fields.length < MAX_FIELDS
    end

    report
  end

  # Produce a report. The mirror of parse(), and the same grammar. Returns an
  # array of lines. An empty body (preamble only) is the conformant REFUSAL for
  # a major this device does not speak -- answering in the wrong major is the
  # violation, not a lenient kindness.
  def emit(info, requested_major: 1, schema: '1.0005', speaks: nil)
    majors = speaks || [schema.split('.').first.to_i]
    out = [format('%-11s%s', 'schema', schema),
           format('%-11s%s', 'speaks', majors.join(' '))]
    return out unless majors.include?(requested_major)

    # `fw <version>` LAST, so a parser can take the final whitespace-separated
    # field without knowing whether `unit` was present.
    appid = if info[:unit].nil?
              format('%s fw %s', info[:token], info[:fw])
            else
              format('%s unit %d fw %s', info[:token], info[:unit].to_i, info[:fw])
            end
    out << format('%-11s%s', 'appid', appid)
    %i[project board built uptime attest].each do |key|
      out << format('%-11s%s', key.to_s, info[key].to_s)
    end
    out
  end

  # A counted block of opaque lines. Returns [] rather than a half-written
  # block if it would be malformed -- the header is a promise about how many
  # lines follow, and a reader will skip exactly that many.
  def special(tag, lines)
    body = Array(lines)
    return [] if tag.nil? || !tag.include?('.') || body.length > MAX_SPECIAL
    return [] unless body.all?(String)

    [format('%-11s%d %s', 'special', body.length, tag)] + body
  end
end
