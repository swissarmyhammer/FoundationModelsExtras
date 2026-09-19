---
assignees:
- claude-code
position_column: todo
position_ordinal: '8780'
title: Document ProcessRunner in README and note the plan.md scope extension
---
## What

`ProcessRunner` landed in `Sources/FoundationModelsExtras/ProcessRunner.swift` (card ^86z4bmc). The CHANGELOG records the public API. The README and `plan.md` do not name it yet.

1. Add a README section for `ProcessRunner`, in the shape of the `IgnoreProcessor` and `Doctorable` sections: one short paragraph on what it does (process group, merged bounded output, timeout with the group kill, the `ProcessRegistry` ledger), and one runnable example.
2. Add a note to `plan.md` §5 beside the `ProcessRegistry` note: `ProcessRunner` fought its way in with the same reason (the Skills package carried its own runner with no link to the registry).

## Acceptance Criteria

- [ ] README holds a `ProcessRunner` section with a runnable example.
- [ ] `plan.md` §5 names `ProcessRunner` beside `ProcessRegistry`.
- [ ] The example in the README is mirrored by a test, as the `IgnoreProcessor` example is.

#docs #process-safety