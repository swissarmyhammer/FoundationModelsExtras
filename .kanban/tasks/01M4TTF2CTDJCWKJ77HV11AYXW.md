---
assignees:
- claude-code
position_column: done
position_ordinal: ff80
title: 'Mail step 1.1: add MailID and SignalID'
---
Add two separate public ULID newtypes in Sources/FoundationModelsExtras/Mail/. Each type has `init()` (a new ULID), `init(_ value: ULID)`, and is Hashable, Sendable, Codable (one ULID string, not an object) and CustomStringConvertible (the ULID string). A MailID is not a SignalID.

Tests in Tests/FoundationModelsExtrasTests/Mail/: two new ids are different; Codable round trip; the encoded JSON is a plain string.

Source of truth: /Users/wballard/github/swissarmyhammer/mailbox.md, sections 4, 5, 8 (step 1). #mail