---
name: task
profiles:
  - kanban
description: Create a single, well-researched kanban task. Use when the user wants to add a task, track an idea, or capture work without entering full plan mode.
license: MIT OR Apache-2.0
compatibility: Requires the `code_context` MCP tool for researching symbols and impact before writing the task, and the `kanban` MCP tool to persist the task on the board. Both are provided by the swissarmyhammer `sah` MCP server; will not function on a harness that does not expose them.
metadata:
  author: swissarmyhammer
  version: "1.0.0"
---

# Task

Create one well-researched kanban task from an idea, request, or bug report.

$ARGUMENTS

## Constraints

- **One task per invocation.** Multiple items → pick the most important, suggest `/plan` for the rest.
- **Research before writing.** No guessing at paths, names, test locations.
- **Ask, don't assume.** Vague requests get the `question` tool.
- **Task quality is non-negotiable** — What + Acceptance Criteria + Tests.
- **Kanban only** — no TodoWrite/TaskCreate.

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


---
title: Task Standards
description: Shared standards for kanban task quality — description template, sizing limits, subtask format, specificity
partial: true
---

### Every task must be actionable

Task descriptions MUST include:

```
## What
<what to implement — full paths of files to create or modify, approach, context>

## Acceptance Criteria
- [ ] <observable outcome that proves the work is done>

## Tests
- [ ] <specific automated test to write or update, with file path>
- [ ] <test command to run and expected result>

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
```

A task without acceptance criteria and tests is not valid. Include enough context that someone reading only the task can implement it.

### Tests must be automated — never ask the user to verify

Every `Tests` section MUST specify automated tests (unit, integration, or end-to-end) that run in CI or via a test command. Never ask a human to perform manual verification, smoke tests, click-throughs, or "try it in the UI."

**Forbidden:** "Manually verify…", "Smoke test by…", "User confirms…", "Open the app and check…", or any criterion whose only check is human observation.

**Required:**
- Backend/library: unit + integration tests against real behavior
- APIs/services: integration tests against the real server
- UI: end-to-end tests (Playwright, Cypress) driving the UI and asserting on observable state
- Bug fixes: a regression test that fails before the fix and passes after

If work is genuinely not testable automatically, rescope or add a preceding task to make it testable. Our job is to do work for users, not make work for them.

### Task sizing limits

| Dimension | Target | Split when |
|-----------|--------|------------|
| Lines of code | 200–500 | > 500 |
| Files touched | 2–4 | > 5 |
| Subtasks | 3–5 | > 5 |
| Concerns | 1 | Multiple |

The subtask cap is the strictest constraint. More than 5 means multiple concerns — split along natural seams and link with `depends_on`. Two small tasks with a dependency beat one mega-task.

### Subtasks are checklist items

Subtasks go in the `description` as GFM checklists (`- [ ]`). No separate "add subtask" API.

### Specificity

Use exact file paths, function names, and type names. "Add `Result` return type to `parse_config` and propagate errors to callers in `main.rs` and `cli.rs`" — not "improve error handling."


---
title: Double-Check the Card
description: Adversarial self-review of a freshly created kanban card before reporting done — re-read it, verify every named path/symbol exists, confirm sections, automated tests, sizing, and observable criteria, then fix-and-re-verify
partial: true
---

### Double-check the card before reporting done

A drafted card is not a finished card. After the task is persisted, run an
adversarial self-review against your own output — drafting and reviewing in one
pass misses stale paths, missing sections, vague criteria, manual-verification
tests, and oversized scope. Do NOT report back until the card passes every
check below.

**Do NOT spawn the diff-oriented `double-check` agent to verify a task card.**
That agent reviews a git diff and skips when there is no diff — a freshly
created card has no diff, so it is the wrong tool. The verification here is a
checklist you run yourself, not the diff critic.

Verify, in order:

1. **Re-read the created card.** Fetch the persisted card with
   `{"op": "get task", "id": "<id>"}` and review the actual stored text — not
   your memory of what you intended to write.

2. **Every named path, function, and type exists.** For each file path,
   function, or type the card references, confirm it is real — via the
   `code_context` MCP tool (`{"op": "search symbol", ...}` /
   `{"op": "get symbol", ...}`) or Glob/Read. This catches stale references and
   invented (hallucinated) names. A card that points at a path that does not
   exist sends the next agent down a dead end.

3. **All four required sections are present:** `## What`,
   `## Acceptance Criteria`, `## Tests`, and `## Workflow`. A card missing any
   of these is not actionable.

4. **The `Tests` section is automated.** No "manually verify…", "smoke test
   by…", "user confirms…", or any criterion whose only check is human
   observation. The standards above forbid this — confirm the produced card
   honors it.

5. **Sizing limits hold:** ≤5 files touched, ≤5 subtasks, one concern. More than
   that means multiple concerns — split along natural seams and link with
   `depends_on`.

6. **Acceptance criteria are observable, not vague.** Each criterion must name a
   concrete, checkable outcome ("returns `404` for unknown ids", "the new test
   passes") — not "works correctly" or "is improved".

**Fix-and-re-verify loop.** On any failure, correct the card with
`{"op": "update task", "id": "<id>", ...}` and then re-run the checks from the
top. Report the card as done only after it passes every check.


---
title: Short IDs
description: How to read and reference kanban tasks by their canonical short id
partial: true
---

## Short IDs — reference tasks by short id, never hand-abbreviated prefixes

Every task's stored identity is its full 26-char ULID (e.g. `01KT6SA4911JQPK09YQRC9RB4G`). For humans, each task also has a **short id**: the **last 7 characters of the ULID, lowercased**, shown as `^<short>` (e.g. `^rc9rb4g`). The short id is never stored — it is always derived from the ULID — and it is the canonical short handle.

**Quote the short id from the tool's `short_id` field.** Every task in `get task` / `list tasks` / `next task` output carries a `short_id` field. When you refer to a task in prose, commits, or chat, copy that value (as `^<short>`). **Never hand-abbreviate the ULID by prefix** (`01KT6SA…`): same-session tasks share long leading runs and a prefix like `01KT6SA` collides across sibling cards. The trailing short id is collision-free.

**References resolve forgivingly** — anywhere a task id is accepted (`get`/`move`/`complete`/`update` task, `depends_on`, the `^` filter atom) you may pass any of:

| Input | Resolves by |
|-------|-------------|
| `01KT6SA4911JQPK09YQRC9RB4G` | full ULID — the stored identity |
| `rc9rb4g` | exact short id (the canonical suffix) |
| `^rc9rb4g` | short id with the `^` sigil |
| `01KT6SAM` | unique ULID prefix (git-style) |

Matching is case-insensitive, and the canonical forms win: a full ULID or exact short id always beats a colliding prefix interpretation. A prefix that matches more than one task **does not resolve** — the tool reports the reference as not found (it does not list the matches), so disambiguate by quoting the full 7-char short id. A prefix only works when it is long enough to be unique on the board; the short same-session prefixes (e.g. `01KT6SA`) that this feature exists to avoid are exactly the ambiguous ones. Display is always the short form.

**Example** — the same task, two ways to name it:

- Full ULID (stored identity): `01KT6SA4911JQPK09YQRC9RB4G`
- Short id (what you write): `^rc9rb4g`

Both resolve to that one task; write the short id.

