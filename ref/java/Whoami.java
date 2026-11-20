/*
 * Whoami.java - read a whoami report.
 *
 * SPDX-License-Identifier: MIT
 *
 * A REPORT ARRIVES FROM SOMETHING NOT YET IDENTIFIED. That is what it is for.
 * Every number in it is therefore input, not instruction -- including the
 * counts that say how far to read. SPEC.md "Reading one safely" is the
 * contract this file implements: the format tells a reader how far to read,
 * and the reader decides how far it is willing to. Both halves are required.
 * A length you trust without a bound is not a safety feature, it is an
 * instruction.
 *
 * NO REGULAR EXPRESSIONS ON UNTRUSTED INPUT, matching every other reference
 * implementation. Java's regex engine backtracks, and a reader whose safety
 * rests on a pattern is one crafted report away from the denial of service the
 * bounds exist to prevent. substring() and charAt() only.
 *
 * Integer.parseInt IS NOT USED. It accepts a leading '+' and '-', and throws on
 * anything else -- so a reader built on it either trusts a signed value from
 * the far end or uses exceptions for ordinary control flow. A count is parsed
 * here by hand, length-capped first, so a value that would wrap never becomes a
 * small number that looks reasonable.
 *
 * NOT A VALIDATOR. It answers "what does this say", bounded and without
 * trusting it. Conformance is a separate, stricter question.
 */

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class Whoami {

    /** Columns 1..GRID hold the label; the value starts after it. */
    public static final int GRID = 11;

    // Bounds. Each exists so a hostile or broken far end cannot make a reader
    // work harder than the reader chose to.
    public static final int MAX_LINES = 500;
    public static final int MAX_SPECIAL = 100;
    public static final int MAX_SPEAKS = 16;
    public static final int MAX_FIELDS = 64;
    public static final int PREAMBLE_MAX = 512;

    private Whoami() {
    }

    /** The canonical failure tokens. Classify on these, never on a message. */
    public enum Kind {
        EMPTY("empty"),
        PREAMBLE("preamble"),
        SCHEMA("schema"),
        SPECIAL("special"),
        BOUNDS("bounds");

        private final String token;

        Kind(String token) {
            this.token = token;
        }

        public String token() {
            return token;
        }
    }

    public static final class WhoamiException extends Exception {
        private static final long serialVersionUID = 1L;

        private final transient Kind kind;

        public WhoamiException(Kind kind, String message) {
            super(message);
            this.kind = kind;
        }

        public Kind kind() {
            return kind;
        }
    }

    public static final class Report {
        public int major;
        public int revision;
        public final List<Integer> speaks = new ArrayList<>();
        public boolean speaksTruncated;
        /** Insertion-ordered, so the report's own field order survives. */
        public final Map<String, String> fields = new LinkedHashMap<>();
        /** Including any past MAX_FIELDS, so a caller can tell it did not see
         * everything rather than the report merely looking complete. */
        public int fieldsSeen;
        public int specialBlocks;
        public int linesRead;
        /**
         * A REFUSAL IS A SUCCESSFUL READ, not an error: the device answered
         * with the frozen preamble alone, which is what one that cannot speak
         * the requested major is required to do, and is the one answer a
         * reader of ANY major is guaranteed to understand.
         */
        public boolean refusal;

        /** Null when absent, never "" -- an absent field and a field whose
         * value is empty are different facts. */
        public String get(String label) {
            return fields.get(label);
        }

        public boolean speaksMajor(int major) {
            return speaks.contains(major);
        }

        public String schema() {
            return major + "." + String.format("%04d", revision);
        }
    }

    /**
     * Non-negative decimal, or -1.
     *
     * Length-capped BEFORE conversion, because a count that wrapped is a count
     * the far end chose, and obeying it is the failure this refuses.
     */
    static int toInt(String s) {
        if (s == null || s.isEmpty() || s.length() > 9) {
            return -1;
        }
        int value = 0;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c < '0' || c > '9') {
                return -1;
            }
            value = value * 10 + (c - '0');
        }
        return value;
    }

    private static boolean isBlank(char c) {
        return c == ' ' || c == '\t';
    }

    private static String trimEnd(String s) {
        int end = s.length();
        while (end > 0 && isBlank(s.charAt(end - 1))) {
            end--;
        }
        return s.substring(0, end);
    }

    private static String trimStart(String s) {
        int start = 0;
        while (start < s.length() && isBlank(s.charAt(start))) {
            start++;
        }
        return s.substring(start);
    }

    /**
     * Label and value, BY SLICE AND NOT BY SPLITTING ON WHITESPACE.
     *
     * Columns 1..GRID are the label, right-trimmed; the rest is the value,
     * left-trimmed. That fixed width is the whole reason the grid exists: it
     * lets a label contain a space -- {@code front end} -- with no escaping and
     * no ambiguity about where it ends. Splitting on the first space instead
     * reads that label as {@code front} and silently moves {@code end} into the
     * value: a corrupted read that looks like a successful one.
     *
     * @return {@code {label, value}}, or null when the line holds no label.
     */
    public static String[] splitLine(String line) {
        if (line == null || trimEnd(trimStart(line)).isEmpty()) {
            return null;
        }
        int cut = Math.min(GRID, line.length());
        String label = trimEnd(line.substring(0, cut));
        if (label.isEmpty()) {
            return null;
        }
        String value = line.length() > GRID ? trimStart(line.substring(GRID)) : "";
        return new String[] {label, value};
    }

    private static void parseSchema(String value, Report report) throws WhoamiException {
        int dot = value.indexOf('.');
        if (dot <= 0 || dot >= value.length() - 1) {
            throw new WhoamiException(Kind.SCHEMA, "schema value not <major>.<4 digits>");
        }
        String revision = value.substring(dot + 1);
        // FOUR DIGITS, zero-padded, always. Fixed width is what makes 1.0012
        // and 1.0002 compare correctly as text, and a reader that accepts 1.12
        // is accepting a report no conformant emitter produces.
        if (revision.length() != 4) {
            throw new WhoamiException(Kind.SCHEMA, "schema value not <major>.<4 digits>");
        }
        int major = toInt(value.substring(0, dot));
        int rev = toInt(revision);
        if (major < 0 || rev < 0) {
            throw new WhoamiException(Kind.SCHEMA, "schema value not <major>.<4 digits>");
        }
        report.major = major;
        report.revision = rev;
    }

    private static void parseSpeaks(String value, Report report) {
        for (String word : splitWhitespace(value)) {
            int major = toInt(word);
            if (major < 0) {
                continue;   // unreadable entry; the rest may be fine
            }
            if (report.speaks.size() < MAX_SPEAKS) {
                report.speaks.add(major);
            } else {
                report.speaksTruncated = true;
            }
        }
    }

    /** Split on runs of blanks, without a regex. */
    private static List<String> splitWhitespace(String s) {
        List<String> out = new ArrayList<>();
        int i = 0;
        while (i < s.length()) {
            while (i < s.length() && isBlank(s.charAt(i))) {
                i++;
            }
            int start = i;
            while (i < s.length() && !isBlank(s.charAt(i))) {
                i++;
            }
            if (i > start) {
                out.add(s.substring(start, i));
            }
        }
        return out;
    }

    /** Parse raw bytes. Lines may end LF or CRLF. */
    public static Report parse(byte[] bytes) throws WhoamiException {
        if (bytes == null || bytes.length == 0) {
            throw new WhoamiException(Kind.EMPTY, "empty report");
        }
        // ISO-8859-1 never fails and never reinterprets a byte, so a report
        // carrying something unexpected is READ rather than refused. UTF-8
        // would substitute replacement characters and shift every later column.
        return parse(new String(bytes, StandardCharsets.ISO_8859_1));
    }

    /** Parse report text. Lines may end LF or CRLF. */
    public static Report parse(String text) throws WhoamiException {
        Report report = new Report();
        if (text == null || text.isEmpty()) {
            throw new WhoamiException(Kind.EMPTY, "empty report");
        }

        // BOUND THE PREAMBLE READ. A device that never sends a newline must not
        // be able to hang a reader, and the preamble's whole value is that the
        // decision is cheap -- so cap the bytes before it has to have landed.
        if (text.length() > PREAMBLE_MAX) {
            int newlines = 0;
            for (int i = 0; i < PREAMBLE_MAX; i++) {
                if (text.charAt(i) == '\n') {
                    newlines++;
                }
            }
            if (newlines < 2) {
                throw new WhoamiException(Kind.BOUNDS,
                        "report exceeded its bound (no newline within the first "
                                + PREAMBLE_MAX + " bytes)");
            }
        }

        List<String> lines = splitLines(text);
        if (lines.size() < 2) {
            throw new WhoamiException(Kind.PREAMBLE, "missing or malformed preamble");
        }

        String[] first = splitLine(lines.get(0));
        if (first == null || !"schema".equals(first[0])) {
            throw new WhoamiException(Kind.PREAMBLE, "missing or malformed preamble");
        }
        report.linesRead++;
        parseSchema(first[1], report);

        String[] second = splitLine(lines.get(1));
        if (second == null || !"speaks".equals(second[0])) {
            throw new WhoamiException(Kind.PREAMBLE, "missing or malformed preamble");
        }
        report.linesRead++;
        parseSpeaks(second[1], report);

        List<String> rest = lines.subList(2, lines.size());
        boolean allBlank = true;
        for (String line : rest) {
            if (!trimEnd(trimStart(line)).isEmpty()) {
                allBlank = false;
                break;
            }
        }
        if (allBlank) {
            report.refusal = true;
            return report;
        }

        int index = 0;
        while (index < rest.size()) {
            String line = rest.get(index);
            index++;
            report.linesRead++;
            if (report.linesRead > MAX_LINES) {
                throw new WhoamiException(Kind.BOUNDS, "report exceeded its line bound");
            }
            String[] field = splitLine(line);
            if (field == null) {
                continue;
            }

            if ("special".equals(field[0])) {
                // `special <count> <tag>` -- the count only. The tag is
                // deliberately not interpreted: not knowing it is the expected
                // case, not an error.
                List<String> words = splitWhitespace(field[1]);
                int count = words.isEmpty() ? -1 : toInt(words.get(0));
                // BOUND THE COUNT. An unbounded count supplied by the far end
                // is a request to read forever. Past the cap it is a malformed
                // report, not an instruction to obey.
                if (count < 0 || count > MAX_SPECIAL) {
                    throw new WhoamiException(Kind.SPECIAL,
                            "special block count past the bound");
                }
                int skip = Math.min(count, rest.size() - index); // truncated: skip what exists
                index += skip;
                report.linesRead += skip;
                if (report.linesRead > MAX_LINES) {
                    throw new WhoamiException(Kind.BOUNDS, "report exceeded its line bound");
                }
                report.specialBlocks++;
                continue;
            }

            report.fieldsSeen++;
            // First match wins; a duplicate label is a conformance question,
            // not a reading one.
            if (report.fields.size() < MAX_FIELDS && !report.fields.containsKey(field[0])) {
                report.fields.put(field[0], field[1]);
            }
        }
        return report;
    }

    private static List<String> splitLines(String text) {
        List<String> out = new ArrayList<>();
        int start = 0;
        for (int i = 0; i < text.length(); i++) {
            if (text.charAt(i) == '\n') {
                int end = i;
                if (end > start && text.charAt(end - 1) == '\r') {
                    end--;
                }
                out.add(text.substring(start, end));
                start = i + 1;
            }
        }
        if (start < text.length()) {
            int end = text.length();
            if (end > start && text.charAt(end - 1) == '\r') {
                end--;
            }
            out.add(text.substring(start, end));
        }
        return out;
    }
}
