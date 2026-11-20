/*
 * Run the shared corpus against ref/java/Whoami.java.
 *
 * SPDX-License-Identifier: MIT
 *
 * Same job and same output shape as every other runner here, so results can be
 * compared line for line. The corpus is the authority; a runner that disagrees
 * with it is reporting a defect in its implementation.
 *
 * Classification is BY ERROR KIND, never by message text: a message is for a
 * human and may be reworded, while the kind is the contract.
 */

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class RunCorpus {

    private RunCorpus() {
    }

    private static Map<String, String> loadExpect(Path path) throws IOException {
        Map<String, String> out = new LinkedHashMap<>();
        String text = new String(Files.readAllBytes(path), StandardCharsets.UTF_8);
        for (String raw : text.split("\n", -1)) {
            if (raw.endsWith("\r")) {
                raw = raw.substring(0, raw.length() - 1);
            }
            if (raw.isEmpty() || raw.startsWith("#")) {
                continue;
            }
            // FIRST equals: a label may contain a space but never an equals
            // sign, which is why this corpus needs no quoting rules.
            int eq = raw.indexOf('=');
            if (eq >= 0) {
                out.put(raw.substring(0, eq), raw.substring(eq + 1));
            }
        }
        return out;
    }

    private static List<String> check(Path corpus, String name) throws IOException {
        List<String> problems = new ArrayList<>();
        byte[] bytes = Files.readAllBytes(corpus.resolve(name + ".report"));
        Map<String, String> expect = loadExpect(corpus.resolve(name + ".expect"));
        boolean wantError = "error".equals(expect.get("status"));

        Whoami.Report report = null;
        try {
            report = Whoami.parse(bytes);
            if (wantError) {
                problems.add("read succeeded, but this case exists to be refused");
            }
        } catch (Whoami.WhoamiException e) {
            String got = e.kind().token();
            if (!wantError) {
                problems.add("threw " + got + " but the case expects a successful read");
            } else if (expect.containsKey("error") && !got.equals(expect.get("error"))) {
                problems.add("error token '" + got + "', corpus says '"
                        + expect.get("error") + "'");
            }
        }

        if (report == null) {
            return problems;
        }

        for (Map.Entry<String, String> entry : expect.entrySet()) {
            String key = entry.getKey();
            String want = entry.getValue();
            if ("status".equals(key) || "error".equals(key)) {
                continue;
            }
            String got;
            if (key.startsWith("field.")) {
                String label = key.substring("field.".length());
                got = report.get(label);
                if (got == null) {
                    problems.add("field '" + label + "' absent, corpus says '" + want + "'");
                    continue;
                }
                if (!got.equals(want)) {
                    problems.add("field '" + label + "' is '" + got + "', corpus says '"
                            + want + "'");
                }
                continue;
            }
            switch (key) {
                case "major":
                    got = Integer.toString(report.major);
                    break;
                case "revision":
                    got = Integer.toString(report.revision);
                    break;
                case "refusal":
                    got = report.refusal ? "true" : "false";
                    break;
                case "blocks":
                    got = Integer.toString(report.specialBlocks);
                    break;
                case "speaks": {
                    StringBuilder sb = new StringBuilder();
                    for (int major : report.speaks) {
                        if (sb.length() > 0) {
                            sb.append(' ');
                        }
                        sb.append(major);
                    }
                    got = sb.toString();
                    break;
                }
                default:
                    continue;
            }
            if (!got.equals(want)) {
                problems.add(key + " is '" + got + "', corpus says '" + want + "'");
            }
        }
        return problems;
    }

    public static void main(String[] args) throws IOException {
        Path corpus = Paths.get(args.length > 0 ? args[0] : "tests/corpus");
        String index = new String(Files.readAllBytes(corpus.resolve("INDEX")),
                StandardCharsets.UTF_8);

        int total = 0;
        int bad = 0;
        for (String raw : index.split("\n")) {
            String name = raw.trim();
            if (name.isEmpty()) {
                continue;
            }
            total++;
            List<String> problems = check(corpus, name);
            if (!problems.isEmpty()) {
                bad++;
            }
            System.out.printf("  %-4s %s%n", problems.isEmpty() ? "ok" : "FAIL", name);
            for (String problem : problems) {
                System.out.println("        " + problem);
            }
        }
        System.out.printf("%n  java: %d cases, %d failed%n", total, bad);
        System.exit(bad > 0 ? 1 : 0);
    }
}
