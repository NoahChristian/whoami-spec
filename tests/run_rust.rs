//! Run the shared corpus against ref/rust/whoami.rs.
//!
//! SPDX-License-Identifier: MIT
//!
//! Same job and same output shape as every other runner here, so results can
//! be compared line for line. The corpus is the authority; a runner that
//! disagrees with it is reporting a defect in its implementation.
//!
//! Built as a single file with rustc, no Cargo and no dependencies: a reader
//! this small should not need a package manager to be checked, and anyone with
//! a toolchain can reproduce the result in one command.

#[path = "../ref/rust/whoami.rs"]
mod whoami;

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

fn load_expect(path: &Path) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    let text = fs::read_to_string(path).unwrap_or_default();
    for raw in text.split('\n') {
        let raw = raw.strip_suffix('\r').unwrap_or(raw);
        if raw.is_empty() || raw.starts_with('#') {
            continue;
        }
        // FIRST equals: a label may contain a space but never an equals sign.
        if let Some(eq) = raw.find('=') {
            out.insert(raw[..eq].to_string(), raw[eq + 1..].to_string());
        }
    }
    out
}

fn check(corpus: &Path, name: &str) -> Vec<String> {
    let mut problems = Vec::new();
    // Read as BYTES, then latin-1 them into a String: read_to_string would
    // reject a report carrying something unexpected, turning a field problem
    // into a total read failure.
    let bytes = fs::read(corpus.join(format!("{name}.report"))).unwrap_or_default();
    let text: String = bytes.iter().map(|b| *b as char).collect();
    let expect = load_expect(&corpus.join(format!("{name}.expect")));
    let want_error = expect.get("status").map(String::as_str) == Some("error");

    let report = match whoami::parse(&text) {
        Ok(report) => {
            if want_error {
                problems.push("read succeeded, but this case exists to be refused".into());
            }
            Some(report)
        }
        Err(err) => {
            let got = err.token();
            if !want_error {
                problems.push(format!(
                    "returned Err({got}) but the case expects a successful read"
                ));
            } else if let Some(want) = expect.get("error") {
                if got != want {
                    problems.push(format!("error token '{got}', corpus says '{want}'"));
                }
            }
            None
        }
    };

    let Some(report) = report else {
        return problems;
    };

    for (key, want) in &expect {
        match key.as_str() {
            "status" | "error" => {}
            "major" => {
                let got = report.major.to_string();
                if &got != want {
                    problems.push(format!("major {got}, corpus says {want}"));
                }
            }
            "revision" => {
                let got = report.revision.to_string();
                if &got != want {
                    problems.push(format!("revision {got}, corpus says {want}"));
                }
            }
            "speaks" => {
                let got = report
                    .speaks()
                    .iter()
                    .map(u32::to_string)
                    .collect::<Vec<_>>()
                    .join(" ");
                if &got != want {
                    problems.push(format!("speaks '{got}', corpus says '{want}'"));
                }
            }
            "refusal" => {
                let got = if report.refusal { "true" } else { "false" };
                if got != want {
                    problems.push(format!("refusal {got}, corpus says {want}"));
                }
            }
            "blocks" => {
                let got = report.special_blocks.to_string();
                if &got != want {
                    problems.push(format!("blocks {got}, corpus says {want}"));
                }
            }
            other => {
                if let Some(label) = other.strip_prefix("field.") {
                    match report.get(label) {
                        Some(got) if got == want => {}
                        Some(got) => problems.push(format!(
                            "field '{label}' is '{got}', corpus says '{want}'"
                        )),
                        None => problems.push(format!(
                            "field '{label}' absent, corpus says '{want}'"
                        )),
                    }
                }
            }
        }
    }
    problems
}

fn main() {
    // The corpus directory, from argv[1] or the conventional location. Taken
    // as an argument rather than derived from the executable's path because
    // rustc puts the binary wherever it was told to, and a reference runner
    // should not depend on that having been somewhere in particular.
    let corpus = std::env::args()
        .nth(1)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("tests").join("corpus"));
    let index = fs::read_to_string(corpus.join("INDEX")).expect("cannot read corpus INDEX");
    let names: Vec<&str> = index.lines().map(str::trim).filter(|l| !l.is_empty()).collect();

    let mut bad = 0usize;
    for name in &names {
        let problems = check(&corpus, name);
        if !problems.is_empty() {
            bad += 1;
        }
        println!("  {:<4} {}", if problems.is_empty() { "ok" } else { "FAIL" }, name);
        for problem in &problems {
            println!("        {problem}");
        }
    }
    println!("\n  rust: {} cases, {} failed", names.len(), bad);
    std::process::exit(if bad > 0 { 1 } else { 0 });
}
