---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m50n2nvndgh7ce8r53wacjef
  text: |-
    Research done.
    - ElicitationStringSchema has custom Codable with CodingKeys; `pattern` goes in CodingKeys, decodeIfPresent, encodeIfPresent, and as the last init parameter.
    - ToolContext.elicit returns `runPlane.awaitAnswer(to:runToken:post:)` directly. The check goes after that call. The headless path returns cancel inside awaitAnswer, so a check that acts only on a form accept leaves it unchanged.
    - Existing accepts in this package (ToolContextTests, RunToCompletionRunnerTests, RunPlaneActorTests, ToolHostingPublicSurfaceTests) are valid against their schemas (`name` string, `ok` boolean, URL accept with nil content). They stay green.
    - ToolContextTests has an ImmediatelyRespondingSink that answers inside post(event:). This gives an event-driven answer with no poll. AnswerDrivenRun and waitUntilPending use bounded waits and AwaitedCondition polls, so the new tests do not use them. The new elicit tests go in a new suite with no time limit, and the sink moves to MountFixtures so that both suites share it.
  timestamp: 2026-10-15T20:46:52.277420+00:00
- actor: claude-code
  id: 01m50nnvnb32nb6rp38zm2kefk
  text: |-
    Implementation landed (no commit, no push).
    - Elicitation.swift: `ElicitationStringSchema.pattern` (decode, encodeIfPresent with the key "pattern", the last init parameter `pattern: String? = nil`).
    - OperationEvents/ElicitationValidation.swift (new): `ElicitationRequestedSchema.invalidAnswerReasonPrefix` and the pure `validationFailure(of:)`. It examines the union of the required names and the content keys in name order, and gives the first failure. Rules: required, unknown key, type (integer = whole number), minLength/maxLength in Characters, pattern (NSRegularExpression, whole match through `\A(?:pattern)\z`; a pattern that does not compile gives a sentence that names it), format email/uri/date/date-time, minimum/maximum, single select values, multi select values/minItems/maxItems.
    - ToolContext.elicit: after the run plane answers, a form accept with a requested schema and a failure becomes `.decline(reason: invalidAnswerReasonPrefix + failure)`. Other answers, URL accepts and the headless cancel are unchanged.
    - README: one bullet in the elicitation section.
    - Tests: ElicitationValidationTests.swift (pattern suite + validator suite, 18 valid and 23 invalid parameterized cases + 5 whole-answer tests), ElicitationValidationPublicSurfaceTests.swift (plain import), Hosting/ToolContextAnswerValidationTests.swift (4 tests, no time limit, no poll). ImmediatelyRespondingSink moved from ToolContextTests to MountFixtures so both suites share it; it now also completes a URL accept.
    - RED (API surface with no logic, validator stub gave a constant failure): 17 tests, 14 failed, 3 passed. The 3 that passed are guards that by nature hold on the old code: no pattern key when there is no pattern, a valid accept stays an accept, a URL accept is not checked.
    - GREEN: 17 of 17 passed. Full `swift test`: 1142 tests in 110 suites passed. No compiler warning; the only warning line is the existing build-system note about the mlx-swift_Cmlx bundle, also present before the change.
    - Push is not done: the last subtask stays open until the coordinating session accepts.
  timestamp: 2026-10-15T20:57:20.811561+00:00
- actor: claude-code
  id: 01m50np6j6jjdjdhtjkhy8q2j0
  text: |-
    Search of the other family packages for accepted form answers with content (Sources, Tests, IntegrationTests; no .build or checkouts). No package was changed.

    Breaks when the package takes this Extras change (the answer goes through ToolContext.elicit):
    - FoundationModelsMultitool Tests/FoundationModelsMultitoolTests/SandboxGlobalsTests.swift:166, :539, :565. The sandbox `elicit("question")` (Sources/FoundationModelsMultitool/MultiTool+SandboxGlobals.swift:675 calls `context.elicit`) makes a form with empty `properties` (the test checks this at :581). The scripted answer `.accept(content: ["repo": ...])` has an unknown key, so the run now gets `.decline` with the reason `the answer is not valid: the field "repo" is not in the requested schema`. Those tests expect an accept. Also a design question for that package: a bare-question form has no field, so only empty or nil content is valid.
    - FoundationModelsMultitool MCPServer+Elicitation.swift:174 relays the elicitation of a downstream MCP server through `context.elicit`, so relayed form answers are now checked too.

    UI paths that can send content that fails (AgentViewKit, from reading the code):
    - ElicitationView.swift:199 sends the form values. ElicitationValidator gates Submit, but: (1) ElicitationFieldSchema.normalize drops a property of a kind it does not support; when that property is required, the content has no such key -> "is required"; (2) defaultValues (ElicitationView.swift:111) keeps "" or [] for an optional field, and the key is sent -> minLength, pattern, format, select values or minItems can fail; (3) ElicitationFieldViews.swift:771 writes [] when the last box is unchecked -> minItems fails on an optional field; (4) ElicitationValidator.swift:144 counts unicodeScalars, Extras counts Characters -> a value with combining marks can pass minLength in the UI and fail here; (5) a field override can write .null or a wrong type.

    Tests with content that breaks the schema but do not go through ToolContext.elicit:
    - swift-sdk Tests/MCPTests/ElicitationTests.swift:447, :522, :604 (keys in an empty schema), :335 (content on a URL accept), :113 (codec test only).

    Valid: the other accepts in FoundationModelsACPAgent, FoundationModelsACPClient, FoundationModelsACP, FoundationModelsRouter, FoundationModelsMultitool (elicitEcho `{answer}`, `{name}`, `{repo}` with a declared schema) and the hosted AgentViewKit tests. Pass-through code (ACPClient PendingElicitation/SessionModel/ConnectionModel, ACPAgent ElicitationRelay:600, Router OperationVocabulary:121) builds no content.
  timestamp: 2026-10-15T20:57:31.974739+00:00
- actor: claude-code
  id: 01m50npcgbwkg2kp1vebvf5p33
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsExtras/OperationEvents/Elicitation.swift, Sources/FoundationModelsExtras/OperationEvents/ElicitationValidation.swift (new), Sources/FoundationModelsExtras/Hosting/ToolContext.swift, README.md, Tests/FoundationModelsExtrasTests/ElicitationValidationTests.swift (new), Tests/FoundationModelsExtrasTests/ElicitationValidationPublicSurfaceTests.swift (new), Tests/FoundationModelsExtrasTests/Hosting/ToolContextAnswerValidationTests.swift (new), Tests/FoundationModelsExtrasTests/Hosting/MountFixtures.swift, Tests/FoundationModelsExtrasTests/Hosting/ToolContextTests.swift. RED filtered: 17 tests, 14 failed, 3 guards passed. GREEN filtered: 17/17. Full swift test: 1142 tests in 110 suites passed. No new compiler warning.
    - next: /review. Push waits for acceptance by the coordinating session. FoundationModelsMultitool SandboxGlobalsTests :166, :539, :565 break when that package takes this change.
  timestamp: 2026-10-15T20:57:38.059140+00:00
position_column: doing
position_ordinal: '80'
title: Validate an accepted form answer against the requested schema, and keep pattern
---
Source: elicitation-plan.md, Extras task 19 (phase 3: the async question path).

Today only the UI checks an answer, and the Extras string schema drops `pattern`, so it does not go over the wire.

- [x] Send the design to the coordinating session, and get acceptance before code.
- [x] Keep `pattern` in `ElicitationStringSchema` (decode, encode, init).
- [x] Add one validation of an accepted form answer against its requested schema.
- [x] A run gets no content that is not valid: give it a decline with the validation failure as the reason.
- [x] Fixed-order tests that fail on the old code. No clock, sleep, poll, retry or time limit.
- [x] Doc comments and README.
- [ ] One full test run. Push only after the coordinating session accepts.

#elicitation-phase-3