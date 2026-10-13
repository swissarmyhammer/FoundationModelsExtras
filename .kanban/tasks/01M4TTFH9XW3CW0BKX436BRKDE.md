---
assignees:
- claude-code
position_column: done
position_ordinal: ff8580
title: 'Mail step 1.6: add MailSink, MailSubscription and MailRefusal'
---
Add `public protocol MailSink: Sendable { associatedtype Event: Sendable; func mail(_ mail: Mail) throws -> MailSubscription<Event> }`.

Add `public struct MailSubscription<Event: Sendable>: AsyncSequence, Sendable` with `public let id: MailID`. It wraps an AsyncStream<Event> with an unbounded buffer. `public init(id: MailID, events: AsyncStream<Event>)`.

Add `public enum MailRefusal: Error, Sendable, Equatable { case duplicateID(MailID); case closed }`.

Doc: `mail` subscribes first, then puts the mail in the queue, thus the caller loses no events. The subscription gives the events whose origin contains the id, up to and including its terminal event, then ends. A caller that does not need the events drops it.

Tests: a test sink (only in the test target) shows that events sent before the first `next()` are not lost, and that the sequence ends after the stream finishes; a duplicate id throws MailRefusal.duplicateID.

Source of truth: /Users/wballard/github/swissarmyhammer/mailbox.md, sections 4, 5, 8. #mail