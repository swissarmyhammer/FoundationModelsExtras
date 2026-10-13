---
assignees:
- claude-code
position_column: done
position_ordinal: ff8480
title: 'Mail step 1.5: add Mail'
---
Add `public struct Mail: Sendable, Codable, Equatable` with `id: MailID`, `sender: MailSender`, `body: MailBody`, and `public init(id: MailID = MailID(), sender: MailSender, body: MailBody)`.

Doc: the caller can give the id (for example the ACP messageId). If not, the init makes a new one. The session refuses a duplicate id (MailSink.mail throws).

Tests: the default id is new each time; a given id is kept; Codable round trip.

Source of truth: /Users/wballard/github/swissarmyhammer/mailbox.md, sections 4, 5, 8. #mail