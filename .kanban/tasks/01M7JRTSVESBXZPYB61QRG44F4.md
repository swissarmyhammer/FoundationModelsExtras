---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7jrxc4x2brxnpjx9mg2nf3v
  text: |-
    Research done.
    - ElicitationRequest has one private memberwise init. The form init and the URL init and relayed(by:askedBy:) call it. The encode already writes agentPath and source only when they have a value; the sensitive key follows the same pattern.
    - ToolContext.elicit sends the request unchanged in the elicitation event (stamped(.elicitation, elicitation: request)). Thus the flag reaches the sink with no code change; a test proves it.
    - Tests: ElicitationRelayTests has the wire-key tests for agentPath and source. ToolContextTests.elicitAcceptRoundTrip shows how to catch the posted event with RecordingSink.
  timestamp: 2026-11-16T18:11:36.221884+00:00
- actor: claude-code
  id: 01m7js5nfrjwd9vga02jfc7w38
  text: |-
    Audit result: Extras has no write of the content of an ElicitationResponse to a log, telemetry, a journal or a mail body. Thus no write changed. Each place that I examined:
    - Mail/MailBody.swift: the case elicitationAnswer(id:response:) holds the answer, but Extras does not make this mail and does not write it. The Router makes it and writes it to the transcript and the recording. The Router must use ElicitationRequest.sensitive there.
    - Mail/MailQueue.swift: the telemetry has only queue tickets, outcomes and counts by MailKind. No body content.
    - OperationEvents/OperationEventSink.swift: post(elicitationEnded:response:) is a protocol hook. The default ignores it. The run plane calls it only for an end of the run plane (a cancel or endElicitation), and a precondition or a guard stops an accept there. Thus the response has no content.
    - Hosting/ToolContext.swift: elicit posts the request (not the answer) in the elicitation event, with its sensitive flag. postElicitationEnded and the mounted sink forward the end response unchanged; the end response has no content. checked(_:to:) gives the answer to the run only.
    - Hosting/ToolRun.swift: post(elicitationEnded:response:) forwards the end upstream. It writes nothing.
    - Hosting/RunPlaneActor.swift: finish(_:with:) writes only the queue outcome (succeeded or cancelled) to QueueTelemetry. The logs (sweep, end inside a sink post, missing id) hold no answer.
    - Telemetry/*: the elicitation queue (QueueTelemetry name elicitation) records tickets and outcomes. ToolCallSpan records tool name, session id and run kind. No answer content.
    Discovery: ElicitationValidationIssue.Kind.itemNotAllowed puts a value of the answer into its failure text. ToolContext.elicit sends that text to the run as the reason of a decline. That is not a log write by Extras, but a tool usually gives a decline reason to the model. I added the task ^96wszdx for it.
  timestamp: 2026-11-16T18:16:07.928482+00:00
- actor: claude-code
  id: 01m7js61b4fkv6xrmv5y4qvg75
  text: |-
    Search of the other packages (read only, no change): FoundationModelsRouter, FoundationModelsACPAgent, FoundationModelsMultitool, FoundationModelsSkills, TestudoApp.
    - No breaks. No code calls the private memberwise init. Each call of the form init or the URL init still compiles, because the new parameter is last and has a default. No test compares the encoded JSON of an ElicitationRequest to fixed text or to a fixed key set: the Router ElicitationEnvelopeTests and OperationEvent tests only do round trips, and the ACPAgent ElicitationAskerMetaTests encode the ACP wire request, not ElicitationRequest. A request that is not sensitive encodes the same bytes as before. No package has a name `sensitive` on these types. FoundationModelsSkills and TestudoApp do not use ElicitationRequest.
    - Places that do not set or carry the flag yet (later work in those packages, not breaks):
      - ACPAgent Settings/AgentMCPServerSecrets.swift question(server:key:) asks for the secret value of an MCP server and does not set sensitive: true.
      - ACPAgent Agent/ElicitationRelay.swift wireRequest(for:...) maps the request field by field to the ACP CreateElicitationRequest; the flag does not go to the client (the _meta of ElicitationAskerMeta could carry it).
      - Router Session/SubagentQuestionRelay.swift uses relayed(by:askedBy:), thus the flag passes through a subagent relay. The Router still must send the answer mail with no content for a sensitive question.
      - Multitool MultiTool+ElicitationHelpers.swift makeElicitRequest reads only message, url and requestedSchema from the sandbox elicit() argument; a sandbox cannot set the flag. Multitool MCPServersTool.askTheUser and MCPServer+Elicitation do not set it (the MCP wire has no such flag).
  timestamp: 2026-11-16T18:16:20.068751+00:00
- actor: claude-code
  id: 01m7js6n239786b5xpczhreq48
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsExtras/OperationEvents/Elicitation.swift, Tests/FoundationModelsExtrasTests/ElicitationSensitiveTests.swift (new, 8 tests), Tests/FoundationModelsExtrasTests/Hosting/ToolContextTests.swift (1 test). RED: the build failed with no member 'sensitive'; then, with only the property and the inits, the encode, round-trip and relay tests failed. GREEN: the 9 tests pass. Full `swift test` exit 0: 1949 + 433 + 156 + 46 + 40 + 35 + 26 tests pass, no compiler warning (only the mlx-swift_Cmlx.bundle build-system line).
    - next: /review. Follow-up task ^96wszdx (decline reason of an answer that is not valid).
  timestamp: 2026-11-16T18:16:40.259760+00:00
- actor: claude-code
  id: 01m7jsady2wmkepd9jatnwtg5j
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit e8f8265). 0 findings, 0 confirmed, 0 refuted. 7 files attempted, 0 failed. 3 files reviewed. 4 .kanban files were not reviewed because of .reviewignore.
    - next: none. The task is in done.
  timestamp: 2026-11-16T18:18:44.034857+00:00
- actor: claude-code
  id: 01m7jsas5md98fm090ggx1dd9k
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 3 files
    - test: green — swift test, 7 runs passed, 0 failed, 0 compiler warnings
    - commit: e8f8265 (amended with the kanban state as 4c413b2)
    - review: clean — 0 findings
  timestamp: 2026-11-16T18:18:55.540554+00:00
position_column: done
position_ordinal: ffec80
title: 'Elicitation: a sensitive flag on ElicitationRequest, so a host keeps the answer to a secret question out of its transcripts and logs'
---
## Why

The answer to an elicitation goes into the answer mail of the Router, and the Router sends that mail to the model transcript and the session recording. When the question asks for a secret, for example the token of an MCP server, the secret leaks. The Router will send the answer mail with no content for a sensitive question. It needs a flag on the request for that. The waiting run still gets the full answer.

## What

In `Sources/FoundationModelsExtras/OperationEvents/Elicitation.swift`:

- Add `public let sensitive: Bool` to `ElicitationRequest`. The doc tells that `true` means the answer holds a secret, and that a host must not write the content of the answer to a transcript, a recording, a log or telemetry. The flag is for the whole question, not for each field.
- Add the parameter `sensitive: Bool = false` to the form-mode init and to the URL-mode init, after the parameters that exist now. Existing calls compile with no change.
- `encode(to:)` writes the key `sensitive` only when the value is `true`. `init(from:)` decodes a missing key as `false`. Thus the wire shape does not change for a question that is not sensitive.
- `relayed(by:askedBy:)` keeps the flag.
- `ToolContext.elicit` sends the request with its flag unchanged.
- Audit each log, telemetry attribute, journal and mail body in Extras that writes the content of an `ElicitationResponse` (look at `Mail/MailBody.swift`, `OperationEvents/OperationEventSink.swift`, `Hosting/ToolContext.swift`, `Hosting/RunPlaneActor.swift`, `Hosting/ToolRun.swift`, and the telemetry). Each such write must not write the content of an answer to a sensitive question. Record in a task comment each write that you found and what you changed, or that there is none.

## Acceptance

- [x] Tests, written before the code: the default is `false`; both inits take the flag; the encode of a request that is not sensitive has no `sensitive` key; the encode of a sensitive request has `"sensitive": true`; a decode with no key gives `false`; a round trip keeps `true`; `relayed(by:askedBy:)` keeps the flag; `ToolContext.elicit` delivers the flag to the host.
- [x] Each content write of the audit is changed, with a test, or the comment tells that none exists.
- [x] Before the push, search other packages (Router, ACPAgent, Multitool, FoundationModelsSkills, TestudoApp under /Users/wballard/github/swissarmyhammer) for tests that compare the encoded JSON of an `ElicitationRequest` or call its memberwise shape in a way that this change breaks.
- [x] `swift test` is green with no compiler warnings.

#elicitation