---
depends_on:
- 01KXX4577MZK2WKK2VHTV9H4FM
- 01KXX45SJ1R0X46CBMYF59DN9K
- 01KXX47408MG0KP7BAQWFKZFDW
- 01KXX47J8F72GSX5STK6YVDQZP
position_column: todo
position_ordinal: '8880'
title: 'Examples/ExtrasDemo: runnable contract test for all three pillars'
---
## What
The living contract test (plan.md §7), mirroring Shelltool's example layout: an `executableTarget` named `extras-demo` at `Examples/ExtrasDemo/Sources/extras-demo`, thin ArgumentParser CLI (add `swift-argument-parser` as a dependency of the example target only — the library's Foundation+Stencil budget is untouched), plus a checked-in fixture tree `Examples/ExtrasDemo/Fixtures/` with `defaults/`, `user/`, `project/` layers so no demo ever touches the real home directory. Isolation mechanism: pass the fixture's `user/` directory via `DotfolderStack`'s public `userDirectory:` defaulted parameter (added by the DotfolderStack task), and point defaults via `EXTRASDEMO_DEFAULTS_DIR` / the `defaultsDirectory:` argument.

This is intentionally one deliverable (plan.md §9 treats the demo as a single build-order item); it is the board's largest task — keep each subcommand thin.

Subcommands, one per pillar:
- [ ] `extras-demo stack` — builds `DotfolderStack` over the fixtures, resolves `config.yaml`, enumerates `commands/*.md`, prints **which layer won each item**; honors `EXTRASDEMO_DEFAULTS_DIR` so repointing changes the answers with no rebuild
- [ ] `extras-demo render <file> [--set key=value]... [--untrusted]` — renders a frontmatter+markdown template showing a context variable, an env variable, a well-known value, and `{% include "header.md" %}` resolved from layered `_partials/` (project fixture shadows user); `--untrusted` demonstrates the trust split against a deliberately bad fixture that renders trusted but is rejected untrusted
- [ ] `extras-demo commands` — registers a demo `SlashCommandProviding` with one `.prompt` command (template rendered before display) and one `.action` command (streams a few lines), invokes both, then ticks `commandUpdates` and prints the re-published set
- [ ] Declare `extras-demo` as a dependency of the test target (Shelltool pattern) so `swift test` builds the binary for subprocess-driven integration tests
- [ ] Fixture tree shared with unit tests where practical

## Acceptance Criteria
- [ ] `swift run extras-demo <stack|render|commands>` all succeed against the checked-in fixtures
- [ ] `stack` output names the winning layer per item; changes when `EXTRASDEMO_DEFAULTS_DIR` is repointed
- [ ] `render --untrusted` exits nonzero with a validation message on the bad fixture, zero without `--untrusted`
- [ ] `commands` output shows the prompt expansion, the streamed action lines, and the updated command set
- [ ] No code path reads the real `~/.extrasdemo` (user layer always injected via `userDirectory:`)

## Tests
- [ ] `Tests/FoundationModelsExtrasTests/ExtrasDemoIntegrationTests.swift` — launches the built `extras-demo` as a subprocess (Shelltool's pattern) and asserts on stdout/exit codes for each acceptance criterion above, including the env-var repoint
- [ ] Run `swift test`; expect all pass

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.