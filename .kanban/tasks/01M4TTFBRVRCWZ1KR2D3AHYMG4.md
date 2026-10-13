---
assignees:
- claude-code
position_column: done
position_ordinal: ff8380
title: 'Mail step 1.4: add MailSender, MailBody and MailKind'
---
Add `public enum MailSender: Sendable, Codable, Hashable { case user; case run(correlationID: String); case elicitation(ULID); case session(ULID) }`. `run` carries OperationEvent.correlationID (the completion token). `session` carries the session id of the sender.

Add `public enum MailBody: Sendable, Codable, Equatable { case userMessage(prompt: String, options: UserMessageOptions); case runEvent(OperationEvent); case elicitationAnswer(id: ULID, response: ElicitationResponse); case agentMessage(from: ULID, content: String) }`.

Add a computed `kind` of type `MailKind` (String raw values: user_message, run_event, elicitation_answer, agent_message). Router uses it as the telemetry dimension `mail.kind`, thus the raw values are stable API. The doc must say this.

Tests: Codable round trip of each case; each kind raw value.

Source of truth: /Users/wballard/github/swissarmyhammer/mailbox.md, sections 4, 5, 8. #mail