---
assignees:
- claude-code
position_column: done
position_ordinal: ffc980
title: 'Pending-work text: no turn language, and a waiting-status line that names each open call'
---
**Problem (bench noqueue24, 2026-10-24).** `PendingRunEnvelope.pendingWorkInstruction` (Hosting/PendingRunEnvelope.swift:43) says "That message starts you working again", which is turn language, and "do nothing: write no text and call no tool", which asks for an empty output that the model cannot produce. In django__django-14672 a child session made 122 runCode snippets that call no tool (`return "stop"`, `"halt"`, ...). In 14580 the root polled `git status` 11 times while its child worked.

**Rule.** The design has no turns. Only the ACP adapter uses the word "turn". Tool results and mail are messages that come in. Text that the model writes is a status message to whoever started it. The tool text must not say "end your answer", "turn", or "starts you working again".

**Change**
1. Rewrite `pendingWorkInstruction` as a generic text: the result arrives as a message, no wait or check is needed, no tool makes it come sooner, go on with other work, and if none is left, post a status in plain text.
2. Add `waitingStatusInstruction(for: [(description, completionToken)])`. It is the one owner of the per-call text, and the Multitool standby answer uses it. The status line is `Waiting on <what> (<token>).`
3. `defaultCollectInstruction(forCompletionToken:describing:)` is that text for one call. When there is no description it falls back to "this call".
4. `BackgroundTool`: add `callDescription(for:)` (default `nil`, which gives the op). The requirement `collectInstruction(forCompletionToken:)` becomes `collectInstruction(forCompletionToken:describing:)`, and the runner passes the description. This is a BREAKING change for tools that override it (Multitool MultiTool+Background, Shell Execute, Agents AgentsTool).
5. Update the wording tests and the README.

**Acceptance**
- [ ] Tests pin the new texts, and no text contains turn language or asks for empty output.
- [ ] The runner's envelope names the call by its description.
- [ ] `swift build` and `swift test` are green with zero warnings. Push main, and send the sha to the ACP session. #hosting