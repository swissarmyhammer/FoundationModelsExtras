---
assignees:
- claude-code
position_column: done
position_ordinal: ff9180
title: ToolContext gives the user presence of its session
---
Add `public var userPresence: UserPresence { runPlane.userPresence }` to `ToolContext`. `ToolContext.runPlane` is internal, so a tool package (for example FoundationModelsMultitool) cannot read the presence today. Multitool needs it to install `elicit` only in interactive sessions.

- [x] Add the property with a doc comment.
- [x] Add a public-surface test with a plain import.
- [x] Add a test that a headless and an interactive run plane give the correct value through `ToolContext`.
- [x] One full test run: 1125 tests pass, no new warnings.
- [ ] The change is additive: push when green, and report the head and CI.

#elicitation-phase-2