---
assignees:
- claude-code
depends_on:
- 01KY2CTRJ0QAFM6N94293DGP5K
- 01KY2CV7EX91J6J9AQBVRZRBXC
position_column: doing
position_ordinal: '80'
title: 'IgnoreProcessor: load ignore files, evaluate paths with verdict + why'
---
## What
Create `Sources/FoundationModelsExtras/IgnoreProcessor.swift` — the public facade. A processor is an ordered list of `IgnoreRule`s with provenance, loaded from any file name (not just `.gitignore`), plus an evaluator.

Construction:
- `init(contentsOf url: URL) throws` — reads the file (UTF-8), parses each line via `IgnoreRule`, `source` = the file's display path/name
- `init(string: String, source: String)` — parse from memory (testing, embedded defaults)
- Loading a missing/unreadable file throws a documented, `CustomStringConvertible` error type mirroring the facade-error style of `DotfolderLoader`

Evaluation — `func evaluate(_ path: String, isDirectory: Bool = false) -> IgnoreVerdict`:
- `path` is a `/`-separated path relative to the ignore file's root (reject/normalize leading `./`; document that absolute paths and `..` are the caller's responsibility to relativize)
- A trailing `/` on `path` is an alternative way to say "this is a directory": it is stripped and forces directory-ness, exactly like `git check-ignore` input. `evaluate("build/")` ≡ `evaluate("build", isDirectory: true)`. This convention is what makes the batch API and CLI able to express directory probes
- Last-match-wins over the rule list; negated rules flip to included
- Anchored rules match the full relative path via wildmatch; unanchored (slash-free) rules are matched as if prefixed with `**/` — equivalently, against the path's final component only (wildcards never cross `/`, so nothing else can match). This applies to directory-only unanchored rules too
- Directory-only rules match only when the probe is a directory — or when the tested path is *inside* a matched directory (see next point)
- Parent-directory exclusion: if any ancestor directory of `path` evaluates to ignored, the path is ignored and cannot be re-included by a negation (git: "It is not possible to re-include a file if a parent directory of that file is excluded"). The verdict's explanation must name the excluded ancestor and the rule that excluded it. (A negation that re-includes the ancestor itself, e.g. `!build/`, does lift the exclusion — only children under a still-excluded ancestor are locked out)
- Convenience `func evaluate(_ paths: [String]) -> [IgnoreVerdict]` for testing one or more paths in a single call; directory probes are expressed with the trailing-slash convention

`IgnoreVerdict` (public, `Sendable`):
- `isIgnored: Bool`, plus a `reason` enum: `.matched(IgnoreRule)`, `.parentExcluded(ancestor: String, by: IgnoreRule)`, `.noRuleMatched`
- `CustomStringConvertible` producing a human-readable why, e.g. `ignored by ".gitignore":3 \`*.log\`` / `included by ".reviewignore":7 \`!important.log\`` / `included (no rule matched)`

All public API fully documented (DocCoverageTests enforces this). Everything `Sendable` and immutable after init, matching prevailing style.

## Acceptance Criteria
- [ ] Loading a file with any name works; verdicts carry that name in explanations
- [ ] Last-match-wins: `*.log` then `!keep.log` → `keep.log` included, `other.log` ignored, and each verdict cites the deciding rule with source + line
- [ ] `build/` ignores `build/out/a.o` via parent exclusion, and `!build/out/a.o` after it does NOT re-include (parent-exclusion rule), with the ancestor named in the explanation
- [ ] Trailing-slash probes: `evaluate("build/")` equals `evaluate("build", isDirectory: true)`; directory-only rule `build/` matches the former, not `evaluate("build")`
- [ ] Unanchored `*.log` matches `deep/nested/x.log`; unanchored `foo` does NOT match `deep/xfoo` beyond its final component (no substring/suffix matching); anchored `/todo.txt` matches only root `todo.txt`
- [ ] `evaluate(_:[String])` returns per-path verdicts in input order, honoring trailing-slash directory probes
- [ ] Missing file throws the documented error; error text names the path

## Tests
- [ ] New `Tests/FoundationModelsExtrasTests/IgnoreProcessorTests.swift` (`@Suite`) covering every bullet, including verdict `description` strings and a fixture written to a temp directory (canonicalize with the existing `realpath` helper pattern if URLs are compared)
- [ ] `swift test --filter IgnoreProcessorTests` passes; full `swift test` green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.