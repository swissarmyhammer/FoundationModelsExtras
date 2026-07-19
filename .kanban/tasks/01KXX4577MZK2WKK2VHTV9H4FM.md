---
depends_on:
- 01KXX44VAM0BR1CM0D7JR9C8XP
position_column: todo
position_ordinal: '8180'
title: 'Slash-command vocabulary: SlashCommand + SlashCommandProviding'
---
## What
Implement plan.md §2 exactly — the cross-package slash-command vocabulary. Signatures must not reference anything harness-shaped.

- `Sources/FoundationModelsExtras/SlashCommand.swift`: `public struct SlashCommand: Sendable` with `name` (no leading slash), `description`, `argumentHint: String?`, and `body: Body`. `public enum Body: Sendable` with `case prompt(template: String)` and `case action(@Sendable (Invocation) -> AsyncThrowingStream<String, Error>)`. `public struct Invocation: Sendable` with `arguments: String` and `workingDirectory: URL`.
- `Sources/FoundationModelsExtras/SlashCommandProviding.swift`: `public protocol SlashCommandProviding: Sendable` with `func commands(workingDirectory: URL) async -> [SlashCommand]` and `var commandUpdates: AsyncStream<[SlashCommand]>? { get }` (nil = static provider).
- Full doc comments on every public declaration, including the trust-boundary sentences from plan.md §5 (`.action` requires linked Swift; data channels are `.prompt`-only) at the type.

## Acceptance Criteria
- [ ] Public API compiles and matches plan.md §2 signatures verbatim
- [ ] All public declarations documented, including the trust boundary at `Body`
- [ ] No imports beyond Foundation in these files

## Tests
- [ ] `Tests/FoundationModelsExtrasTests/SlashCommandTests.swift`:
  - a fake static conformer returns commands and `commandUpdates == nil`
  - a `.prompt` body round-trips its template string
  - an `.action` body streams multiple chunks collected via `for try await`, and a throwing action surfaces its error
  - a dynamic fake provider ticks `commandUpdates` and the test observes the re-published set
- [ ] Run `swift test`; expect all pass

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.