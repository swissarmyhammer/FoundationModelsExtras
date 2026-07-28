---
comments:
- actor: claude-code
  id: 01kymhb9j68nhfhkwwk4anmjmp
  text: |-
    Implemented via TDD.

    Research: grepped this repo for every `SlashCommand.Body` consumer (SlashCommandTests.swift, DemoCommandProvider.swift, CommandsCommand.swift) and confirmed no exhaustive `switch` exists anywhere — only non-exhaustive `guard case .prompt` / `guard case .action` patterns. So adding a case is purely additive and non-breaking for all existing conformers/dispatchers. Also read FoundationModelsACPAgent/plan.md §6.3 (lines ~826-864) which is the actual upstream ask driving this card — it proposes the exact shape `case rendered(@Sendable (Invocation) async throws -> String)`, so used that name and signature verbatim.

    RED: added three tests to Tests/FoundationModelsExtrasTests/SlashCommandTests.swift referencing `.rendered` before it existed — confirmed compile failure ("Type 'SlashCommand.Body' has no member 'rendered'") via both LSP diagnostics and a real `swift test` run.

    GREEN: added `case rendered(@Sendable (Invocation) async throws -> String)` to `SlashCommand.Body` in Sources/FoundationModelsExtras/SlashCommand.swift, with doc comments stating the tiering (data sources -> `.prompt` only; linked code -> `.action` (streams, no model) or `.rendered` (prompt, model turn)) and preserving `.prompt(template:)`'s original "only body kind data sources may produce" annotation unchanged. `swift build` and `swift test` both green: 229/229 tests across 21 suites, including the "Public API doc coverage" suite (new case's doc comments satisfy the package's doc-coverage gate).

    Tests added (Tests/FoundationModelsExtrasTests/SlashCommandTests.swift):
    - renderedBodyProducesThePromptStringTheDispatcherWouldTreatAsTheTurnsInput
    - renderedBodyReceivesTheInvocationsArgumentsAndWorkingDirectory
    - renderedBodyThrowingSurfacesAsADiagnosableErrorRatherThanAnEmptyPrompt

    Verification: `swift build` exit 0; `swift test` 229/229 passed (fresh runs, both before and during really-done). Adversarial double-check agent returned PASS with no findings — confirmed signature matches ACPAgent's plan.md ask verbatim, no Swift 6 concurrency issues, all acceptance criteria met, existing .prompt/.action tests unaffected.

    Leaving task in `doing` per /implement workflow — ready for /review.
  timestamp: 2026-07-28T14:16:36.166059+00:00
- actor: claude-code
  id: 01kymhwpf7w4tgee722x5fkm6f
  text: |-
    Fixed the one open review finding: updated the `Invocation` doc comment in Sources/FoundationModelsExtras/SlashCommand.swift to say "The context an `.action` or `.rendered` body runs with..." (was `.action`-only). Scanned the rest of the file for the same staleness class — no other doc comment there mentions `.action` in a way that omits `.rendered`; the `.action` case's own comment describes only that case's semantics, which is fine. Checked repo-wide for other doc comments on the shared `Invocation` type — none found outside SlashCommand.swift (plan.md is historical, Examples/ demo comments are local to `.action`, not about `Invocation`).

    Checkbox marked `- [x]` in the description's Review Findings section.

    Verification: `swift build` clean (no warnings/errors), `swift test` 229/229 passing. really-done double-check agent returned PASS with no findings.

    Leaving task in `doing` for `/review` to pick up.
  timestamp: 2026-07-28T14:26:06.439040+00:00
position_column: doing
position_ordinal: '80'
title: 'SlashCommand.Body: a provider-rendered prompt case'
---
## What

**Upstream ask from `FoundationModelsACPAgent`** (its `plan.md` §6.3), found while reviewing whether `FoundationModelsSkills` can actually deliver slash commands through `SlashCommandProviding`.

`SlashCommand.Body` currently offers exactly two cases (`Sources/FoundationModelsExtras/SlashCommand.swift:41-48`):

```swift
case prompt(template: String)                                              // the data lane
case action(@Sendable (Invocation) -> AsyncThrowingStream<String, Error>)  // the code lane
```

**A skills-style provider fits neither**, so `SlashCommandProviding` cannot currently express its own flagship consumer.

## Why neither case works

**Not `.prompt(template:)`.** The dispatcher renders that template with Extras' Stencil engine. Skills renders with its *own* pipeline and its own substitution model — `$0` / `$1` / `$ARGUMENTS[N]` / `$name` positional arguments, `_partials/` includes, macOS shell injection, and its own trust-tier mapping per stack layer. Handing the raw `SKILL.md` body over as a "template" would have it rendered under the wrong substitution rules. That does not fail loudly; it produces **silently wrong prompt text**, which is the worst available outcome.

**Not `.action(...)`.** That case is documented as "Runs code, streams text output, **never touches the model**." A skill command is the opposite: its whole purpose is that the rendered body *becomes the model turn's input*. The consumer's own §7.1 shows the shape — `registry.call(id:arguments:)` → `root.respond(to: rendered)`.

## The ask

A third body kind that **computes a prompt and then takes an ordinary model turn**:

```swift
case rendered(@Sendable (Invocation) async throws -> String)
```

The conformer renders; the dispatcher feeds the returned string to the model exactly as it would a `.prompt`. `Invocation` already carries what is needed (`arguments`, `workingDirectory`).

Naming is yours — `.rendered`, `.computedPrompt`, `.promptProvider`. The requirement is the *semantics*: provider-side rendering, model-side consumption.

## The trust boundary survives — this is why it is safe to add

The existing split is that **data may only ever produce a prompt**, and `.prompt` is annotated "The only body kind data sources may produce." That rule is untouched:

- A closure can only be constructed by **linked Swift**, so untrusted markdown still cannot reach it. Data keeps its single lane.
- The new case lets *linked code* produce **model input** rather than **streamed output** — a capability `.action` deliberately withholds, but one that carries no new authority, since anything a linked conformer could put in a `.rendered` string it could equally have put in a `.prompt` template.

So the tiers become: data → `.prompt`; linked code → `.action` (streams, no model) or `.rendered` (prompt, model turn).

## Also worth confirming

Should `.prompt(template:)` stay? Once `.rendered` exists, a conformer could pre-render trivially. It should stay — it is the **only** case a data source can produce, and collapsing it into a closure would erase exactly the distinction the trust boundary depends on.

## Acceptance Criteria

- [ ] `SlashCommand.Body` gains a case whose payload is an async closure returning the prompt text.
- [ ] The doc comments state the tiering: data → `.prompt` only; linked code → `.action` or the new case.
- [ ] `.prompt(template:)` is retained with its data-lane annotation intact.
- [ ] A throwing render surfaces as a command error, not a silently empty prompt.
- [ ] Existing conformers and dispatchers compile unchanged.

## Tests

- [ ] A conformer returning the new case renders on invocation and the returned string is what the dispatcher would treat as the turn's prompt.
- [ ] The closure receives the invocation's `arguments` and `workingDirectory`.
- [ ] A throwing render produces a diagnosable error rather than an empty or partial prompt.
- [ ] `.prompt` and `.action` behavior is unchanged.

## Workflow

- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-07-28 09:19)

- [x] `Sources/FoundationModelsExtras/SlashCommand.swift:65` — The doc comment for `Invocation` states it is 'The context a `.action` body runs with', but `Invocation` is now also used by the newly added `.rendered` case, making the documentation incomplete and misleading. Update the documentation to reflect both use cases: 'The context an `.action` or `.rendered` body runs with: the arguments the user typed after the command's name, and the session's working directory.'.
