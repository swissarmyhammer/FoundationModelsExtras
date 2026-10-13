---
assignees:
- claude-code
depends_on:
- 01M4TTF2CTDJCWKJ77HV11AYXW
position_column: done
position_ordinal: ff8180
title: 'Mail step 1.2: add Origin'
---
Add `public enum Origin: Sendable, Codable, Hashable { case mail(Set<MailID>); case signal(SignalID); case system }` in Sources/FoundationModelsExtras/Mail/.

Doc: each output event has one origin. `mail` is an answer to a batch of mail. `signal` is work that a signal started (a compaction). `system` is session work that no mail or signal started, errors also. Do not add a @TaskLocal here (Router adds it in step 2).

Tests: Codable round trip of each case; the equality of mail sets does not depend on the order.

Source of truth: /Users/wballard/github/swissarmyhammer/mailbox.md, sections 4, 5, 8. #mail