---
assignees:
- claude-code
position_column: done
position_ordinal: ff8280
title: 'Mail step 1.3: add UserMessageOptions'
---
Add `public struct UserMessageOptions: Sendable, Codable, Hashable` with `maxTokens: Int?` and `mode: Mode`, and `public enum Mode: String { case reply, stream }`. The default init gives maxTokens nil and mode reply.

Doc: a guided session never streams. Router enforces this, not this type. Router maps this type to its SubmissionOptions.

Tests: the defaults; Codable round trip.

Source of truth: /Users/wballard/github/swissarmyhammer/mailbox.md, sections 4, 5, 8. #mail