---
assignees:
- claude-code
depends_on:
- 01KY2CVY2Y8VH8YVHVM0JXPZ0N
- 01KY2CWS0NK4QPWZT1VT7FZF63
position_column: todo
position_ordinal: '8380'
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