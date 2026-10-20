---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5b181e3erewf86vsexd2tst
  text: 'Picked up. Research: the only two call entry points are MountRunner.call -> ToolMounting.call (String tools; it then calls callInBackground/callToCompletion, never ToolMounting.call again, so firing there is once per call) and ContextBindingTool.call (non-String; settle() has no other caller). ToolContext.runSite comes from the site of the call via held(by:settlingBy:), so a context of an inner call keeps the witness and the flag; its own mount() sets the flag again anyway. MountSite.childSite builds through the public child init, so the child gets nil witness and flag false with no extra code. The ToolContext convenience init (sessionID/runPlane/sink) builds a site with no witness: hosts that want the seam pass a site with a witness to makeWrapped. Plan: new Hosting/ToolCallWitness.swift (protocol + WitnessedToolCall), MountSite gains callWitness + internal witnessesCalls flag + `witnessingInnerCalls` copy + `witnessCallStart(of:arguments:)`, ToolContext.mount sets the flag.'
  timestamp: 2026-10-19T21:31:55.203996+00:00
- actor: claude-code
  id: 01m5b1gpd51kr7wepgyajphsh6
  text: |-
    Implementation landed (not committed). New Sources/FoundationModelsExtras/Hosting/ToolCallWitness.swift (protocol ToolCallWitness + struct WitnessedToolCall, exactly the card API). MountSite: `let callWitness`, `private(set) var witnessesCalls` (false from the private init), `callWitness:` defaulted param on both public inits, internal `witnessingCalls` copy and `witnessStart(ofCallTo:arguments:)`. ToolContext's private mount builds `runSite.posting(...).witnessingCalls`. Fired at the head of ToolMounting.call and ContextBindingTool.call. childSite goes through the public child init with no witness, so it drops it with no extra code (documented).
    What did not work: `witnessStart(arguments: some Sendable)` fails to compile from ContextBindingTool, whose generic Arguments is not constrained Sendable; the parameter is `some ConvertibleFromGeneratedContent` instead (the call is synchronous, nothing crosses an isolation boundary).
    Tests: swift test --filter ToolCallWitness 12/12 pass; full swift test 1300 tests in 128 suites pass, only the known mlx-swift_Cmlx "missing creator" warning.
  timestamp: 2026-10-19T21:36:38.821776+00:00
- actor: claude-code
  id: 01m5b1grz7mve0p9wgeqz2j3tk
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsExtras/Hosting/ToolCallWitness.swift (new), Sources/FoundationModelsExtras/Hosting/ToolMounting.swift, Sources/FoundationModelsExtras/Hosting/ToolContext.swift, Sources/FoundationModelsExtras/Hosting/ContextBindingTool.swift, Tests/FoundationModelsExtrasTests/Hosting/ToolCallWitnessTests.swift (new); swift test --filter ToolCallWitness 12/12 pass; swift test 1300 tests / 128 suites pass, zero new warnings
    - next: /review; the push/send subtask stays open (not done by this step)
  timestamp: 2026-10-19T21:36:41.447242+00:00
- actor: claude-code
  id: 01m5b1q2jv3sb9w06kk9jgymqp
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (06adccb) — 0 findings, 0 confirmed, 0 refuted; 7 validator passes attempted, 0 failed, 0 skipped; 5 files reviewed, 4 .kanban/ files excluded by .reviewignore
    - next: orchestrator pushes to origin/main and sends the sha and final API to foundationmodelsrouter-75
  timestamp: 2026-10-19T21:40:07.899689+00:00
- actor: claude-code
  id: 01m5b1qgxex96q1wtadag6sjyp
  text: |-
    ### finish iteration 1 — clean
    - implement: changed (5 files)
    - test: green (swift test: 1300 tests, 128 suites, only the known mlx metal warning)
    - commit: 06adccb
    - review: clean (0 findings)
    - next: push together with the AgentLaunching card (^SFDK6), then send the sha to router-75
  timestamp: 2026-10-19T21:40:22.574136+00:00
position_column: done
position_ordinal: ffad80
title: 'ToolCallWitness: MountSite reports the start of each mounted call, outer and inner'
---
Request from foundationmodelsrouter-75, for acpagent-a5, narrowed in its second message. The Router wants to hint a root session to hand a bug fix to an agent. In the bench, the model edits through runCode → tools.files.edit. Those inner calls go through ToolContext.mount, so the Router never sees them. The Router's own decorator already sees each outer, model-facing call with its arguments. So the witness reports ONLY the calls that ToolContext.mount mounts (the inner calls of a run), never an outer call: reporting outer calls too would count them twice. The Router owns all the state and the hint. Extras gives only the seam. The change must be additive: existing callers compile without change.

API, in Sources/FoundationModelsExtras/Hosting (a new ToolCallWitness.swift, or HostingSeams.swift):
```swift
public protocol ToolCallWitness: Sendable {
    /// Called once at the start of each inner call that ToolContext.mount mounted on a site with this witness.
    func toolCallWillBegin(_ call: WitnessedToolCall)
}
public struct WitnessedToolCall: Sendable {
    public let tool: String                  // the tool name
    public let op: String                    // the op of the mount, or the tool name when there is none
    public let arguments: GeneratedContent?  // when Arguments is ConvertibleToGeneratedContent, else nil
    public let sessionID: ULID               // the session of the site
    public init(tool:op:arguments:sessionID:)
}
```

- [x] MountSite stores `callWitness: (any ToolCallWitness)?`. Add a `callWitness: (any ToolCallWitness)? = nil` parameter to BOTH public inits (the root one and the child one), and pass it through the private init.
- [x] MountSite also stores an internal flag, for example `witnessesCalls: Bool`, default false. Only the site that `ToolContext.mount` builds (ToolContext.swift:681, the private mount) sets it to true. A site that the host gives to `ToolMounting.makeWrapped` keeps false, so an outer call is never reported.
- [x] The copies (`posting`, `held`, `settling`, `postingToSession`) keep the witness and the flag. A context of an inner call holds the witness through its runSite, so an inner call that mounts further inner calls also reports them.
- [x] `MountSite.childSite(sessionID:runPlane:sink:)` (and so `ToolContext.childSite`) drops the witness: the child gets nil, and the flag goes back to false. Document this.
- [x] Fire exactly once per inner call, before the call runs, only when the flag is set and a witness is present, at the two entry points:
  - `ToolMounting.call(_:arguments:site:mount:)`, which covers String tools, background and run-to-completion;
  - `ContextBindingTool.call(arguments:)`, which covers tools whose output is not String.
  - No path may fire twice.
- [x] The call is synchronous and never blocks. The witness never changes, delays or fails a call.
- [x] The arguments are `(arguments as? any ConvertibleToGeneratedContent)?.generatedContent`.
- [x] Doc comments in the style of the file. Mention the seam in the docs of ToolContext.mount and of the MountSite inits.
- [x] Tests (Swift Testing, new file Tests/FoundationModelsExtrasTests/Hosting/ToolCallWitnessTests.swift), with a recording witness:
  - an outer call on a site with a witness gives NO report;
  - an inner call through `ToolContext.mount(_:op:as:)` inside an outer call gives exactly one report, with tool, op (the mount op, else the tool name), arguments and sessionID;
  - `mount(_:op:as:postingTo:)` also reports;
  - an inner run-to-completion tool, an inner background tool and an inner non-String tool each report once;
  - two inner calls give two reports, in order;
  - an inner call of an inner call is reported;
  - a childSite of a site with a witness gives no report for its inner calls;
  - a site with no witness changes nothing;
  - an inner tool that throws still reports once, and the error is unchanged.
- [x] Full `swift test` is green with zero warnings, apart from the known Swift Build metal warning (see ^8pa1503).
- [ ] After done: push to origin/main, then send the sha and the final API to foundationmodelsrouter-75.