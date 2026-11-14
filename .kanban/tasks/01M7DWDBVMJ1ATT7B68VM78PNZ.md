---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7dxvqtehpt369kjmaa50cat
  text: |-
    Research: `op` is read in `OperationResolver.extractedOpString` (explicit non-empty `op`, else the `inferOp` hook), matched by `matchOpString`, and `OperationTool.resolve` throws `.unknownOperation(valid:)` on no match. Each op declares its parameters as `[ParamMeta]` (`OperationDefinition.parameterMetadata`, carried on `AnyOperation.parameters`). The real `skills` tool is in FoundationModelsSkills (`SkillsTool.swift`, `UseSkill`, `ListResource`, ...): six ops, and `{id}` fits both `use skill` and `list resource`, so unique-fit inference alone does not fix the evidence call. No op carries read-only metadata, and both fitting ops are read-only, so a read-only tie-break still ties. Chosen: a per-tool `OperationResolver(defaultOp:)`, used only among fitting ops, beside the existing per-tool `inferOp` hook. The skills tool must name `use skill` in FoundationModelsSkills `SkillsTool.makeResolver()` (follow-up).
  timestamp: 2026-11-14T21:01:53.358058+00:00
- actor: claude-code
  id: 01m7dxvqtfqrv9pzvbkkq71s9x
  text: |-
    What changed in an existing test: `OperationToolTests.missingOpFieldEntirelyReturnsCorrectiveMessage` sent `{"title": "Groceries"}` with no op and expected a corrective. That key fits only `add note`, so it is now inferred, which is the behavior this card asks for. The test is now `missingOpFieldWithKeysThatFitNoOperationReturnsCorrectiveMessage` with `{"subject": ...}`, a key that fits no op.

    Note for FoundationModelsSkills: `PlainTextOperations` matches the plain-text ops with marker operations that declare no parameters, so it will not infer `use skill` for an op-less `{id}` payload, and the answer of an inferred `use skill` stays a JSON string. That follow-up must give the markers the parameters of their targets (or reuse the resolver's inferred op) along with `defaultOp: "use skill"`.

    ### implement — changed
    - evidence: 5 files — Sources/Operations/OperationResolver.swift, Sources/Operations/OperationTool.swift, Tests/OperationsTests/OperationArgumentToleranceTests.swift (new, 16 tests), Tests/OperationsTests/OperationToolTests.swift (one test reshaped), docs/GUIDE.md. RED: 7 of 16 new tests failed for the missing feature; GREEN: 16 of 16. `swift build --build-tests`: no warnings in the changed code. `swift test`: 2547 tests in 7 runs, 0 failures.
    - next: review, then the FoundationModelsSkills follow-up (`defaultOp: "use skill"`, PlainTextOperations).
  timestamp: 2026-11-14T21:01:53.358058+00:00
position_column: doing
position_ordinal: '80'
title: Be liberal in the operation arguments that OperationTool dispatches (unwrap a lone `arguments`, infer a missing `op`)
---
## What
Recursive Flint, a GLM-format tool caller, drives operation tools with argument shapes that `Sources/Operations/OperationTool.swift` refuses with "Unknown operation". After the retry cap ("Too many invalid operation attempts in a row") the agent stops. Seen on a SWE-bench run of the FoundationModelsACPAgent harness (django-13447), on the `skills` tool:

1. `{"id": "kanban"}` and `{"id": "code-analyzing"}` have no `op` key. Four "Unknown operation" errors hit the retry cap, and the child agent died.
2. `{"arguments": {"id": "kanban", "op": "use skill"}}` puts the real arguments in one `arguments` object. "Unknown operation", retry cap, the agent quit after 14 s.

The real `skills` tool (FoundationModelsSkills) has six operations: `search skill` (query*, limit), `list skill` (filter), `use skill` (id*, arguments), `list resource` (id*), `read resource` (id*, path*, start, end), `run script` (id*, path*, arguments, timeout). The keys `{id}` fit both `use skill` and `list resource`, so "fits exactly one operation" alone does not fix case 1. Both of them are read-only, and the operations have no read-only metadata, so a read-only tie-break does not fix it either. A tool therefore declares a default op on its `OperationResolver` for an op-less payload that fits several operations.

- [x] Unwrap: when the payload has one key, `arguments`, whose value is an object or a JSON string of an object, dispatch on the inner object. One level only.
- [x] Infer: when `op` is missing (or empty) and the `inferOp` hook gives nothing, infer the op whose parameters the given keys fit. Fits: the payload has at least one key, each key resolves to a parameter of the op (canonical name, alias, or normalized), and the payload covers every required parameter of the op.
- [x] Exactly one fit: dispatch to it. Several fits: dispatch to the resolver's `defaultOp` when it is one of them. Otherwise, and for zero fits: keep "Unknown operation" with the list of valid operations.
- [x] Unwrapping comes before inference. An explicit `op` is never overridden. Well-formed arguments dispatch as before.
- [x] `mount(for:)` uses the same unwrapped payload and inferred op as `call(arguments:)`.
- [x] Dense `///` doc comments with the rule, task id in comments; docs/GUIDE.md names the two tolerances.

## Acceptance Criteria
- [x] On a fixture tool that mirrors the six `skills` operations with `defaultOp: "use skill"`, `{"id": "kanban"}` dispatches to `use skill`.
- [x] `{"arguments": {"id": "kanban", "op": "use skill"}}` and its JSON-string form dispatch to `use skill`.
- [x] Without a default op, `{"id": "kanban"}` on that mirror still gives "Unknown operation" with the valid operations.
- [x] `swift build --build-tests` and `swift test` are green, with zero warnings in the changed code.

## Tests
- [x] Hermetic tests in `Tests/OperationsTests/` for: the two evidence shapes, a JSON-string `arguments`, an ambiguous missing op that still errors, a zero-fit and an empty payload that still error, a default op that does not fit, and well-formed arguments unchanged.

## Follow-up
FoundationModelsSkills `SkillsTool.makeResolver()` must pass `defaultOp: "use skill"` for case 1 to be fixed in the real tool, and `PlainTextOperations` must see the same inferred op so that the answer of an inferred `use skill` decodes to plain text.

#bug