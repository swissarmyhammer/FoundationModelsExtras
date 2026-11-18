---
assignees:
- claude-code
position_column: done
position_ordinal: fffb80
title: Unarchive on the session directory, and the inbox for an archived target
---
Archive of a session is not final. An archive hides the session. It does not delete it.

## Work
- [ ] `SessionDirectory.unarchive(_:by:)`, with no default implementation. Change the doc of `archive(_:by:)`: unarchive is its inverse.
- [ ] `SessionDirectoryEvent.unarchived(id:)`, after `archived`.
- [ ] A message to an archived target goes to its inbox: receipt `sent`, reason `archived`, one `messageQueued`. The session stays archived, and no turn starts.
- [ ] Change the doc of `SessionSendReceipt.reason`: the reason of a refusal, or a note of a `sent` receipt.
- [ ] Remove `InMemorySessionDirectory.Refusal.archived`. No other package names it.
- [ ] An archive keeps each queued message as an unread message of the inbox.
- [ ] `InMemorySessionDirectory.unarchive`: the state becomes `idle`, the session is not live, the directory sends `stateChanged(idle)` and then `unarchived`. A session that is not archived gives its summary and no event.

## Tests
- [ ] Archive then unarchive: state `idle`, not live, events `stateChanged(idle)` then `unarchived`.
- [ ] Unarchive of a session that is not archived: no event, the same summary.
- [ ] A message to an archived session: `sent` with reason `archived`, one `messageQueued`, no `messageDelivered`, state stays `archived`; after an unarchive the inbox gives the message.
- [ ] Archive of a working session with a queued message: after an unarchive the message is unread in the inbox.
- [ ] `Codable` round trip of `unarchived`. #archive-undo