---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01ky2rpa57ajtejndjebpr099d
  text: |-
    Implemented `+`/`+=` on IgnoreProcessor in IgnoreProcessor.swift: added a private `init(rules:)` and the two operators (list concatenation, lhs rules then rhs rules; +=  as sugar for lhs = lhs + rhs). Documented both prominently in the type's doc comment with the gitignore+reviewignore motivating example.

    Tests (TDD, written first then made green):
    - Tests/FoundationModelsExtrasTests/IgnoreProcessorCombinationTests.swift — override-on-combine (verdict cites winning source+line), reversed-order flips winner, parent exclusion by lhs survives rhs negation on a child, rhs can lift an lhs parent exclusion by re-including the ancestor itself, associativity over a probe set, += accumulation and its equivalence to +.
    - Tests/FoundationModelsExtrasTests/IgnoreProcessorCombinationGitParityTests.swift — new file reusing GitParityHarness from IgnoreGitParityTests.swift. Materializes a repo via GitParityHarness.materializeRepo, then overwrites .git/info/exclude (git init seeds it with template comments, which would offset line numbers vs our parser) with our own lower-precedence rules, and compares IgnoreProcessor(exclude) + IgnoreProcessor(gitignore) verdicts against `git check-ignore --verbose`. Gated on git availability via the same conditional-skip pattern.

    All green: `swift test --filter IgnoreProcessor` (33 tests), `swift test --filter IgnoreGitParityTests` (2 tests), full `swift test` (189 tests in 18 suites, including "Public API doc coverage").
  timestamp: 2026-07-21T16:38:37.479605+00:00
depends_on:
- 01KY2CVY2Y8VH8YVHVM0JXPZ0N
- 01KY2CWS0NK4QPWZT1VT7FZF63
position_column: doing
position_ordinal: '80'
title: Combine processors with + (e.g. .gitignore + .reviewignore)
---
## What
Add `static func + (lhs: IgnoreProcessor, rhs: IgnoreProcessor) -> IgnoreProcessor` in `Sources/FoundationModelsExtras/IgnoreProcessor.swift` (or a small extension file if the type file is getting long).

Semantics:
- The combined processor's rule list is `lhs` rules followed by `rhs` rules, provenance intact — with last-match-wins evaluation this means the right operand's rules override the left's on conflict (mirrors git's own layering where later sources win)
- Verdict explanations from a combined processor cite the winning rule's original source file and line, so "why" survives combination
- Combination is associative: `(a + b) + c` evaluates identically to `a + (b + c)`
- Also add `+=` for ergonomic accumulation, and document both

Document the operator prominently in the type's doc comment with the motivating example: `let ignores = try IgnoreProcessor(contentsOf: gitignoreURL) + IgnoreProcessor(contentsOf: reviewignoreURL)`.

Git-parity for `+`: git layers `.git/info/exclude` (lower precedence) under `.gitignore` (higher), which maps exactly to `IgnoreProcessor(excludeFile) + IgnoreProcessor(gitignore)`. Add a parity test reusing the repo-materialization and `git check-ignore --stdin --verbose --non-matching` helpers from `IgnoreGitParityTests.swift` (this task depends on that task): write rules into `.git/info/exclude` that `.gitignore` overrides, and assert combined verdicts agree with git. Gate on git availability with the same conditional-skip.

## Acceptance Criteria
- [ ] `.gitignore` saying `*.log` + `.reviewignore` saying `!important.log` → `important.log` included, verdict cites `.reviewignore` with its line; `debug.log` ignored, verdict cites `.gitignore`
- [ ] Reversed combination order flips which rule wins, demonstrating last-match-wins across sources
- [ ] Parent-directory exclusion still holds across combined sources (dir excluded by lhs cannot be re-included by an rhs negation on a child)
- [ ] Associativity verified: `(a + b) + c` and `a + (b + c)` produce identical verdicts over a probe path set
- [ ] Combination parity: with git installed, `.git/info/exclude` + `.gitignore` layering verdicts agree with `git check-ignore --verbose`; skips cleanly without git

## Tests
- [ ] Extend `Tests/FoundationModelsExtrasTests/IgnoreProcessorTests.swift` (or add `IgnoreProcessorCombinationTests.swift` if the suite is large) covering every bullet above; the parity case lives beside the helpers in `IgnoreGitParityTests.swift`
- [ ] `swift test --filter IgnoreProcessor` and `swift test --filter IgnoreGitParityTests` pass; full `swift test` green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.