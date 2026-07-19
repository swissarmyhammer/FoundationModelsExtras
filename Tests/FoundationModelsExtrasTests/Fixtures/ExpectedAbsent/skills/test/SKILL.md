---
name: test
description: Run tests and analyze results. Use when the user wants to run the test suite or test specific functionality.
agent: tester
license: MIT OR Apache-2.0
compatibility: Requires the `kanban` MCP tool  for recording test failures as tasks.
metadata:
  author: swissarmyhammer
  version: "1.0.0"
---

# Test

**Zero failures. Zero warnings. Zero skipped. The build is clean or it's broken.**


## Guidelines

---
title: Coding Standards
description: Shared coding standards for all agents
partial: true
---

---
title: Validator Compliance
description: Rules for how agents must respond to validator feedback
partial: true
---

## Validator Feedback

Validators are automated quality gates on your changes. When one blocks you (Stop or PostToolUse hook), its output is **authoritative and mandatory** — not advisory.

**Validator feedback is part of your task.** A task isn't done until all validators pass. Fixing validator issues is the final step, never "off task."

When a validator blocks:

1. **Read the full message.**
2. **Fix every issue.** Apply the specific fixes the validator describes; don't partially address.
3. **Re-verify** before attempting to stop again.

**Never treat validator output as:** a distraction, deferrable, overzealous, or noise to acknowledge but ignore.

If you genuinely believe it's a false positive, explain your reasoning to the user and ask — do not silently ignore it.


## Code Quality

**Take your time. Optimize for correctness, not speed.**

**Seek the global maximum.** The first working solution is rarely the best. Ask: is this the right place for this logic? Does it fit the architecture, or am I just making it compile?

**Minimal means no wasted concepts — not the quickest path to green.** Avoid duplication and unnecessary abstractions, but the right abstraction beats three copy-pasted lines. Override any default "try the simplest thing" instinct.

- Follow existing patterns and conventions; don't invent new ones
- Stay on task — no unrelated refactors or scope creep
- Within the task, find the best solution, not just the first one that works
- Keep functions small and focused; avoid deep nesting; cap at ~50 lines

## Reuse & Data-Driven Design

Left unchecked, generated code trends toward duplication and hardcoding. Push the other way by default.

- **Reuse before re-implementing.** Before writing a new function, search for one that already does it (`search symbol` / `grep code`). A near-match you can extend beats a fresh copy.
- **Extract before copy-pasting.** Two blocks that differ only by a value are one function with an argument. Don't paste-and-tweak.
- **Be data-driven.** Before hardcoding a value or enumerating cases in control flow, ask whether it's *data*. A `match`/`if`-chain over a known set whose arms differ only in constants is a table, not branching. Repeated literals are a named constant or config entry. Express variation as data (tables, maps, config, declarative specs) interpreted by a single code path — not as parallel code paths a human must keep in lockstep.
- **Calibrate, don't over-correct.** Warranted generalization removes *existing* duplication or serves a *real* variation axis. Rule of three: two occurrences is coincidence, three is a pattern. No second caller → no parameter. The right abstraction beats three copies; the wrong abstraction is worse than five.

## Style

Match the project's existing naming, formatting, indentation, and quoting. Respect any formatter config (prettier, rustfmt, black).

## Documentation

- Every function has a docstring covering what it does, params, returns, errors
- Update stale docs touched by your changes
- Comments explain *why*, not *what*

## Error Handling

Handle errors at appropriate boundaries. Trust internal code and framework guarantees — don't add defensive code for impossible scenarios.

---
title: Architecture Awareness
description: Read and respect ARCHITECTURE.md when it exists at the project root
partial: true
---

### Architecture Awareness

If an `ARCHITECTURE.md` file exists at the project root, read it before you act.
It is the project's own description of how the system is structured — its
modules and layers, the boundaries between them, and which direction
dependencies are allowed to flow. Treat it as authoritative context, the same
way you treat the code itself.

- **Orient with it.** Use it to place what you find — or what you build — inside
  the documented structure, instead of reconstructing the architecture from
  scratch by reading files.
- **Respect its boundaries.** Code should land in the module or layer the
  document assigns to it, and must not create dependency edges the document
  forbids (for example, a handler reaching past a service layer straight into
  storage).
- **Flag divergence.** If the work genuinely diverges from or extends the
  documented architecture — a new module, a new dependency direction, a new
  component — say so, and note that `ARCHITECTURE.md` needs an update to match.
  A stale architecture document is worse than none.

If no `ARCHITECTURE.md` exists, skip this — do not create one as a side effect.
The `/map` skill generates it deliberately when that is the goal.


## Process

1. **Run the full test suite** using project detection to pick the right command.
2. **Type-check + lint** with warnings as errors (`cargo clippy -- -D warnings`).
3. **Check for skipped/ignored tests** — fix or delete each. Skips are not acceptable.
4. **Fix every failure and warning**, re-running after each fix. Trace before editing: `get symbol` on the failing function, `get callgraph` (inbound) to see callers, and — if you're changing a shared symbol — `get blastradius` on the file to spot passing tests elsewhere that the change could break.
5. **Track remaining failures on kanban.** Ensure tag exists:

   ```json
   {"op": "add tag", "id": "test-failure", "name": "Test Failure", "color": "ff0000", "description": "Failing test or type check"}
   ```

   Create one task per failure:

   ```json
   {"op": "add task", "title": "<concise description>", "description": "<file:lines>\n\n<error>\n\n<what you tried>", "tags": ["test-failure"]}
   ```

6. **Report**: pass/fail, what was fixed, what's left. If stuck, say what you tried and where you're blocked.

## Rules

- All tests pass. A partial pass is a fail.
- All warnings resolved. Warnings are bugs that haven't bitten yet.
- Skipped tests are broken (fix) or dead (delete) — never acceptable.
- Place new/relocated code per `ARCHITECTURE.md` if one exists.
- Never silence: no `#[allow(...)]`, `@suppress`, `// eslint-disable`.
- Never skip: no `#[ignore]` or `skip` to make a test stop failing.

## Troubleshooting

### No Tests

Make one to get started. 

### A single test hangs and the suite never finishes

Test waits on something CI can't deliver (network, child process, file watcher, deadlock). Run with a hard per-test timeout and isolate the offender via the `shell` tool's `timeout`:

- Rust: `timeout 60 cargo nextest run --test-threads=1 <test_name>` — nextest has no `--timeout` flag; its per-test budget is config-only via `slow-timeout`/`terminate-after` in `.config/nextest.toml`, so wrap the invocation with the shell `timeout` to bound a single suspect test
- Python: `pytest --timeout=60` (needs `pytest-timeout`)
- Node: `jest --testTimeout=60000`

Re-run the offending test with `RUST_LOG=trace` / `--verbose` to find the wait, fix the underlying cause.

### Tests pass locally, fail in parallel ("address in use", missing files)

Tests share mutable state — cwd, env var, fixed port, shared temp file. Serialize with the project's isolation primitive, don't disable parallelism globally:

- Rust: `#[serial_test::serial]`; `CurrentDirGuard` / `tempfile::TempDir` for cwd/files
- Python: `@pytest.mark.serial`; `tmp_path` fixture for filesystem
- Node: `test.serial(...)` (ava); bind port `0` and read it back

Never permanently set `--test-threads=1` — it masks the bug.

### Flaky test (passes on retry)

Non-determinism — timing, unordered iteration, clock, external state. Reproduce deterministically before fixing:

- Rust: `for i in {1..100}; do cargo test <name> -- --nocapture || break; done`
- Python: `pytest -x --count=100 <path>::<name>` (needs `pytest-repeat`)

Remove the source (sort iteration, inject a clock, seed RNGs) — don't add retries.

### `cargo clippy -- -D warnings` fails on a lint you didn't introduce

Toolchain bump enabled a new lint. Fix, don't silence. Auto-fix first:

```
cargo clippy --fix --allow-staged --all-targets
cargo clippy -- -D warnings
```

For lints auto-fix can't handle: `cargo clippy --explain <lint_name>`, rewrite the code. Never `#[allow(...)]`.
