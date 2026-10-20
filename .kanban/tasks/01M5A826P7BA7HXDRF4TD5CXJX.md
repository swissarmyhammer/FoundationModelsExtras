---
assignees:
- claude-code
depends_on:
- 01M5A81YQHG3XMW3RB71WTJNVS
position_column: done
position_ordinal: ffa980
title: 'CatalogNoticeBoard: post a catalog change to each live session that mounted the tool'
---
The delivery half of the catalog-change notice. Depends on the CatalogChangeNotice task.

## What
- `CatalogNoticeSink` protocol (in HostingSeams.swift): `func post(catalogNotice: CatalogChangeNotice) async`. The session sink of a host conforms to it. It is found with a runtime cast, the same way as `ToolCallReportSink`, so that `OperationEventSink` and the `MailBody` switches of the Router do not change. A sink that does not conform drops the notice.
- `CatalogNoticing` protocol: a tool gives `catalogNoticeBoard`.
- `CatalogNoticeBoard` (final class, Sendable, Mutex): `post(_:)` sends the notice to the session sink of each live session that registered with the board. It sends one notice to each session, also when the tool is mounted twice in a session.
- `ToolMounting.makeWrapped(tool:site:configuration:)` registers the site of a `CatalogNoticing` tool with its board. Root sessions and child sessions both mount through it, so both register.
- A session leaves the board when its `WorkRegistry` closes (the Router closes it when the session closes). Add an internal close hook on `WorkRegistry` for that.

## Tests (write them first, see them fail)
`Tests/FoundationModelsExtrasTests/CatalogNoticeBoardTests.swift`
- [ ] a mounted CatalogNoticing tool gets the notice on the sink of its session
- [ ] a root session and a child session (childSite) each get it one time
- [ ] a session whose tool is mounted twice gets one notice
- [ ] a session that does not have the tool gets none
- [ ] after `workRegistry.close()`, the session gets none and the board does not keep it
- [ ] a sink that is not a CatalogNoticeSink: nothing happens and nothing crashes #catalog-notice