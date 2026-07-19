---
comments:
- actor: claude-code
  id: 01kxxq0k0s53m5w3ees785hjcw
  text: |-
    Implemented Examples/ExtrasDemo per plan.md section 7:

    - Package.swift: added swift-argument-parser dependency (scoped to the example target only), a new executableTarget "extras-demo" at Examples/ExtrasDemo/Sources/extras-demo, and added "extras-demo" as a FoundationModelsExtrasTests dependency (mirrors FoundationModelsShelltool's shell-demo pattern).
    - Fixture tree at Examples/ExtrasDemo/Fixtures/{defaults,user,project/.extrasdemo}/ with config.yaml + commands/*.md per layer (hello only in defaults, status shadowed by user, ps shadowed all the way to project) and _partials/header.md in each layer to prove nearest-wins; plus Fixtures/render/{good.md,bad.md} standalone template fixtures.
    - Executable sources: main.swift (root AsyncParsableCommand with 3 subcommands), DemoFixtures.swift (fixed fixture paths derived from #filePath, never from cwd or home), StackCommand.swift, RenderCommand.swift, DemoCommandProvider.swift + CommandsCommand.swift.
    - New Tests/FoundationModelsExtrasTests/ExtrasDemoIntegrationTests.swift (plain import, no @testable) launching the built binary as a subprocess in a throwaway temp cwd, covering all acceptance criteria including the EXTRASDEMO_DEFAULTS_DIR repoint and the trusted-vs-untrusted bad-fixture split.

    TDD: wrote the integration test first against the unmodified Package.swift, confirmed RED (binary not found, 5/5 failing for the right reason), then implemented and reached GREEN.

    Verification: swift test -> 95 tests in 11 suites, all passing, zero warnings on a clean rebuild (rm -rf .build then swift build --build-tests). Manually ran each subcommand and confirmed output matches the acceptance criteria (layer-winner reporting, env-var repoint changing answers with no rebuild, render trusted/untrusted split on the bad fixture, commands prompt/action/commandUpdates flow).

    Adversarial double-check agent dispatched for sign-off before leaving this in doing for review.
  timestamp: 2026-07-19T17:33:04.921552+00:00
- actor: claude-code
  id: 01kxxq8kzb8syxn1vt2vy1nt36
  text: |-
    Adversarial double-check agent returned PASS, no findings: confirmed all three subcommands run cleanly against the fixtures per every acceptance criterion (per-item layer winners, trusted/untrusted split with correct exit codes and validation message, prompt/action/commandUpdates flow), independently verified the EXTRASDEMO_DEFAULTS_DIR repoint behavior and that the fixture directory structure matches DotfolderStack's actual resolution logic, reran swift test (95/95 passing), and confirmed swift-argument-parser is scoped only to the extras-demo target.

    Re-ran swift test once more just now: 95 tests in 11 suites, all passing, zero failures.

    Leaving this task in doing, ready for /review.
  timestamp: 2026-07-19T17:37:28.043355+00:00
- actor: claude-code
  id: 01kxxr7m64y497qdxms4y6wasf
  text: |-
    Pulled back into doing to address the 6 review findings, all confined to Examples/ExtrasDemo/Sources/extras-demo/ (plus one small additive library change described below):

    1/2. Extracted DemoCommandProvider.greetCommandName and .streamCommandName as static constants; both SlashCommand definitions and CommandsCommand.swift's `first(where:)` lookups now reference the constants instead of duplicating "greet"/"stream" literals.
    3. DemoCommandProvider.init() no longer uses an IUO local (`Continuation!`). Changed to `var continuation: Continuation?`, force-unwrapped once at the assignment site with a comment noting AsyncStream's build closure runs synchronously.
    4/5. StackCommand.swift: added `private static let configFileName = "config.yaml"` and replaced all three literal occurrences (the `nearest(...)` call and both print statements) with it.
    6. StackCommand.swift: replaced the `label(for:)` switch over DotfolderStack.Source with `private static let sourceLabels: [DotfolderStack.Source: String]`. Since DotfolderStack.Source (in Sources/FoundationModelsExtras/DotfolderStack.swift) was only Equatable (not Hashable), changed its conformance from `Equatable` to `Hashable` (Hashable implies Equatable; enum has no associated values so this is an automatic, additive synthesis with no other call sites affected — verified via grep, Source is used nowhere else in the library beyond its own declaration).

    Verification: clean rebuild (`rm -rf .build && swift build --build-tests`) succeeded with zero warnings; `swift test` -> 95 tests in 11 suites, all passing. Manually reran `swift run extras-demo stack` and `commands` to confirm unchanged runtime behavior.

    Marked all 6 Review Findings checkboxes [x] on this task. Dispatched an adversarial double-check agent for sign-off before leaving in doing.
  timestamp: 2026-07-19T17:54:24.068110+00:00
- actor: claude-code
  id: 01kxxrb3kdbdy67c1k2h5rb8xt
  text: |-
    Adversarial double-check agent returned PASS, no findings: confirmed all 6 review findings fixed at the root (grep-verified no remaining "greet"/"stream" name-comparison literals, no remaining "config.yaml" literals outside the new constant, no other switch-over-Source code paths), the Hashable conformance change to DotfolderStack.Source has no other dependents, and swift build (clean rebuild) + swift test (95/95 passing, zero warnings) confirmed independently. No stray refactors found.

    Task description's 6 Review Findings checkboxes are all [x]. Leaving in doing, ready for /review.
  timestamp: 2026-07-19T17:56:18.157323+00:00
- actor: claude-code
  id: 01kxxsgzpgj66dnxr4z5vax0km
  text: |-
    Pulled back into doing to address the two 2026-07-19 12:59 review findings.

    Fix 1 (DemoCommandProvider.swift force-unwrap): replaced the IUO-local + force-unwrap pattern in init() with AsyncStream.makeStream(of:), which returns the stream and continuation directly as a tuple, so no optional/force-unwrap is needed at all:
        let (stream, continuation) = AsyncStream.makeStream(of: [SlashCommand].self)
        commandUpdates = stream
        updatesContinuation = continuation
    Behavior is unchanged; the existing commandsShowsPromptExpansionStreamedActionLinesAndTheUpdatedSet integration test (subprocess-driven) continues to exercise init()/commandUpdates/publishStatusCommandAdded() end to end and still passes.

    Fix 2 (DotfolderStack.swift path traversal via `name`): added a private static isSafeDotfolderName(_:) check (non-empty, no "/", not exactly ".") alongside the existing isSafeRelativePath, and a precondition at the top of init() that traps on an unsafe name -- since name combines with a literal "." prefix to form the dotfolder ".<name>", a name containing "/" could inject extra path components (including a literal ".." among them), and name == "." alone becomes "..".

    TDD: wrote 3 new exit tests in DotfolderStackTests.swift first (initTrapsWhenNameContainsAPathSeparator, initTrapsWhenNameIsASingleDot, initTrapsWhenNameIsEmpty) using Swift Testing's `await #expect(processExitsWith: .failure) { ... }`, confirmed RED against the unmodified code (all 3 failed with "expected .failure, got .exitCode(EXIT_SUCCESS)"), then implemented the fix and confirmed GREEN.

    Verification: clean rebuild (`rm -rf .build && swift build --build-tests`) succeeded with zero warnings; `swift test` -> 98 tests in 11 suites, all passing (was 95, +3 new).

    Marked both 2026-07-19 12:59 Review Findings checkboxes [x]. Dispatched an adversarial double-check agent for sign-off before leaving in doing.
  timestamp: 2026-07-19T18:16:59.344281+00:00
- actor: claude-code
  id: 01kxxsmxargpjkx8aaksqavwtc
  text: |-
    Adversarial double-check agent returned PASS, no findings: independently confirmed no force-unwraps/IUOs remain in Examples/ExtrasDemo/Sources or Sources/FoundationModelsExtras, confirmed the AsyncStream.makeStream(of:) refactor preserves behavior (ExtrasDemoIntegrationTests.commandsShowsPromptExpansionStreamedActionLinesAndTheUpdatedSet passes, including the commandUpdates republish assertion), confirmed isSafeDotfolderName + precondition in DotfolderStack.init closes the path-traversal vector (name="" -> ".", name="." -> "..", name containing "/" -> injected components, all three covered and no other degenerate case exists for a "/"-free non-"." string), confirmed every existing DotfolderStack(name:...) call site across Sources/Tests/Examples passes a safe literal name, and independently re-ran `swift build --build-tests` (clean) and `swift test` (98/98 passing) to confirm.

    Both 2026-07-19 12:59 Review Findings checkboxes are [x]. Leaving in doing, ready for /review.
  timestamp: 2026-07-19T18:19:07.992797+00:00
depends_on:
- 01KXX4577MZK2WKK2VHTV9H4FM
- 01KXX45SJ1R0X46CBMYF59DN9K
- 01KXX47408MG0KP7BAQWFKZFDW
- 01KXX47J8F72GSX5STK6YVDQZP
position_column: done
position_ordinal: '8880'
title: 'Examples/ExtrasDemo: runnable contract test for all three pillars'
---
## What
The living contract test (plan.md §7), mirroring Shelltool's example layout: an `executableTarget` named `extras-demo` at `Examples/ExtrasDemo/Sources/extras-demo`, thin ArgumentParser CLI (add `swift-argument-parser` as a dependency of the example target only — the library's Foundation+Stencil budget is untouched), plus a checked-in fixture tree `Examples/ExtrasDemo/Fixtures/` with `defaults/`, `user/`, `project/` layers so no demo ever touches the real home directory. Isolation mechanism: pass the fixture's `user/` directory via `DotfolderStack`'s public `userDirectory:` defaulted parameter (added by the DotfolderStack task), and point defaults via `EXTRASDEMO_DEFAULTS_DIR` / the `defaultsDirectory:` argument.

This is intentionally one deliverable (plan.md §9 treats the demo as a single build-order item); it is the board's largest task — keep each subcommand thin.

Subcommands, one per pillar:
- [x] `extras-demo stack` — builds `DotfolderStack` over the fixtures, resolves `config.yaml`, enumerates `commands/*.md`, prints **which layer won each item**; honors `EXTRASDEMO_DEFAULTS_DIR` so repointing changes the answers with no rebuild
- [x] `extras-demo render <file> [--set key=value]... [--untrusted]` — renders a frontmatter+markdown template showing a context variable, an env variable, a well-known value, and `{% include "header.md" %}` resolved from layered `_partials/` (project fixture shadows user); `--untrusted` demonstrates the trust split against a deliberately bad fixture that renders trusted but is rejected untrusted
- [x] `extras-demo commands` — registers a demo `SlashCommandProviding` with one `.prompt` command (template rendered before display) and one `.action` command (streams a few lines), invokes both, then ticks `commandUpdates` and prints the re-published set
- [x] Declare `extras-demo` as a dependency of the test target (Shelltool pattern) so `swift test` builds the binary for subprocess-driven integration tests
- [x] Fixture tree shared with unit tests where practical

## Acceptance Criteria
- [x] `swift run extras-demo <stack|render|commands>` all succeed against the checked-in fixtures
- [x] `stack` output names the winning layer per item; changes when `EXTRASDEMO_DEFAULTS_DIR` is repointed
- [x] `render --untrusted` exits nonzero with a validation message on the bad fixture, zero without `--untrusted`
- [x] `commands` output shows the prompt expansion, the streamed action lines, and the updated command set
- [x] No code path reads the real `~/.extrasdemo` (user layer always injected via `userDirectory:`)

## Tests
- [x] `Tests/FoundationModelsExtrasTests/ExtrasDemoIntegrationTests.swift` — launches the built `extras-demo` as a subprocess (Shelltool's pattern) and asserts on stdout/exit codes for each acceptance criterion above, including the env-var repoint
- [x] Run `swift test`; expect all pass

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-07-19 12:40)

- [x] `Examples/ExtrasDemo/Sources/extras-demo/DemoCommandProvider.swift:13` — The command name 'greet' is hardcoded in DemoCommandProvider.swift and also searched for in CommandsCommand.swift, creating coupling that must be kept in sync. Extract to a shared constant in DemoCommandProvider (e.g., static let greetCommandName = "greet") and reference it from CommandsCommand.
- [x] `Examples/ExtrasDemo/Sources/extras-demo/DemoCommandProvider.swift:22` — The command name 'stream' is hardcoded in DemoCommandProvider.swift and also searched for in CommandsCommand.swift, creating coupling that must be kept in sync. Extract to a shared constant in DemoCommandProvider (e.g., static let streamCommandName = "stream") and reference it from CommandsCommand.
- [x] `Examples/ExtrasDemo/Sources/extras-demo/DemoCommandProvider.swift:56` — Implicitly unwrapped optional (`Type!`) used as a local variable — the rule forbids this in non-test code except for `@IBOutlet` and test fixtures set in `setUp()`. Use `var continuation: AsyncStream<[SlashCommand]>.Continuation? = nil` and then force-unwrap at the assignment site only if necessary, or restructure to avoid the IUO pattern.
- [x] `Examples/ExtrasDemo/Sources/extras-demo/StackCommand.swift:24` — The literal string 'config.yaml' appears again in the print statement on this line, part of the repeated literal already flagged on line 23. Use the same constant extracted for line 23 here and on line 26.
- [x] `Examples/ExtrasDemo/Sources/extras-demo/StackCommand.swift:26` — The literal string 'config.yaml' appears a third time in the else-branch print statement, part of the repeated literal flagged on line 23. Use the same constant extracted for line 23 here as well.
- [x] `Examples/ExtrasDemo/Sources/extras-demo/StackCommand.swift:46` — The label() function contains a switch statement over a known enum (DotfolderStack.Source) where each arm returns only a constant string. This is a table that should be expressed as data rather than parallel code paths. Extract to a dictionary: static let sourceLabels: [DotfolderStack.Source: String] = [.defaults: "defaults", .user: "user", .project: "project"].

## Review Findings (2026-07-19 12:59)

- [x] `Examples/ExtrasDemo/Sources/extras-demo/DemoCommandProvider.swift:61` — Force unwrap of optional variable is not permitted in non-test code. Although the comment explains the AsyncStream closure is called synchronously, the rule prohibits force unwraps without exceptions. Refactor to avoid the force unwrap. For example, use a guard statement: `guard let continuation = continuation else { fatalError(...) }; self.updatesContinuation = continuation`. Alternatively, if the documented synchronous guarantee is reliable, consider that the pattern may need to be revisited; if it is a known-safe idiom in this codebase, document that exception in the coding guidelines.
- [x] `Sources/FoundationModelsExtras/DotfolderStack.swift:100` — Path traversal vulnerability: the `name` parameter is appended to the home directory path using `appendingPathComponent` without validation. An attacker could pass `name="../../../etc"` to escape the intended dotfolder hierarchy and access arbitrary files on the filesystem. Validate the `name` parameter in `init()` to reject values containing `..` or `/`. Use a check similar to `isSafeRelativePath()` before constructing layer paths: `guard !name.contains(".") && !name.contains("/") else { fatalError(...) }` or similar.
