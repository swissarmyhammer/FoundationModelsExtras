---
comments:
- actor: claude-code
  id: 01kxxdz8vrx5087vfayqk8wykf
  text: 'Implemented via TDD. Wrote Tests/FoundationModelsExtrasTests/SlashCommandTests.swift first (static provider, .prompt round-trip, .action streaming + throwing, dynamic provider commandUpdates tick), confirmed it failed to compile (SlashCommand/SlashCommandProviding did not exist yet), then added Sources/FoundationModelsExtras/SlashCommand.swift and Sources/FoundationModelsExtras/SlashCommandProviding.swift matching plan.md §2 verbatim, with doc comments on every public declaration including the trust-boundary sentences on Body. swift test: 51 tests in 7 suites passed, 0 failures, no warnings (includes the pre-existing DocCoverageTests, which also passed against the new files).'
  timestamp: 2026-07-19T14:55:04.568232+00:00
- actor: claude-code
  id: 01kxxe38hg1rg3zs3b4hytdtbt
  text: 'Double-check adversarial review returned PASS, no findings: SlashCommand/Body/Invocation match plan.md §2 field-for-field and case-for-case; only Foundation imported in both source files; every public declaration has a directly-attached doc comment, and Body carries the plan.md §5 trust-boundary sentence; SlashCommandProviding signature matches exactly. Test file covers all four required scenarios with real assertions. Independent fresh swift test run confirmed 51 tests / 7 suites / 0 failures, no warnings, including DocCoverageTests passing against the real source tree. Leaving task in doing for /review.'
  timestamp: 2026-07-19T14:57:15.312106+00:00
depends_on:
- 01KXX44VAM0BR1CM0D7JR9C8XP
position_column: doing
position_ordinal: '80'
title: 'Slash-command vocabulary: SlashCommand + SlashCommandProviding'
---
## What
Implement plan.md §2 exactly — the cross-package slash-command vocabulary. Signatures must not reference anything harness-shaped.

- `Sources/FoundationModelsExtras/SlashCommand.swift`: `public struct SlashCommand: Sendable` with `name` (no leading slash), `description`, `argumentHint: String?`, and `body: Body`. `public enum Body: Sendable` with `case prompt(template: String)` and `case action(@Sendable (Invocation) -> AsyncThrowingStream<String, Error>)`. `public struct Invocation: Sendable` with `arguments: String` and `workingDirectory: URL`.
- `Sources/FoundationModelsExtras/SlashCommandProviding.swift`: `public protocol SlashCommandProviding: Sendable` with `func commands(workingDirectory: URL) async -> [SlashCommand]` and `var commandUpdates: AsyncStream<[SlashCommand]>? { get }` (nil = static provider).
- Full doc comments on every public declaration, including the trust-boundary sentences from plan.md §5 (`.action` requires linked Swift; data channels are `.prompt`-only) at the type.

## Acceptance Criteria
- [x] Public API compiles and matches plan.md §2 signatures verbatim
- [x] All public declarations documented, including the trust boundary at `Body`
- [x] No imports beyond Foundation in these files

## Tests
- [x] `Tests/FoundationModelsExtrasTests/SlashCommandTests.swift`:
  - a fake static conformer returns commands and `commandUpdates == nil`
  - a `.prompt` body round-trips its template string
  - an `.action` body streams multiple chunks collected via `for try await`, and a throwing action surfaces its error
  - a dynamic fake provider ticks `commandUpdates` and the test observes the re-published set
- [x] Run `swift test`; expect all pass

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.