@testable import FoundationModelsExtras
import Foundation
import FoundationModels
import Testing
import ULID

/// Exercises ``CatalogNoticeBoard``: each live session that mounted a
/// ``CatalogNoticing`` tool gets each posted notice one time, on the sink of
/// the session.
@Suite("Catalog notice board: a catalog change reaches each live session that has the tool")
struct CatalogNoticeBoardTests {
    private typealias Fixtures = MountFixtures

    /// A session sink that keeps each catalog notice, in post order.
    actor NoticeSink: OperationEventSink, CatalogNoticeSink {
        /// Each notice, in post order.
        nonisolated let notices = Recorder<CatalogChangeNotice>()

        /// Drops `event`: these tests read only the notices.
        func post(event: OperationEvent) {}

        /// Keeps `notice`.
        func post(catalogNotice notice: CatalogChangeNotice) {
            notices.append(notice)
        }
    }

    /// A tool that lists a catalog, and posts its changes through `board`.
    struct CatalogTool: Tool, CatalogNoticing {
        let name = "catalog_tool"
        let description = "lists a catalog"
        let catalogNoticeBoard: CatalogNoticeBoard

        func call(arguments: MountArguments) async throws -> String {
            arguments.value
        }
    }

    /// A tool with no catalog.
    struct PlainTool: Tool {
        let name = "plain_tool"
        let description = "has no catalog"

        func call(arguments: MountArguments) async throws -> String {
            arguments.value
        }
    }

    /// One added skill.
    private static let notice = CatalogChangeNotice(
        kind: .skills, added: [CatalogEntry(name: "x", description: "does x")], removed: [], changed: [])

    /// A root session: its id, its registry, its sink and its mount site.
    private struct Session {
        let registry: WorkRegistry
        let sink: NoticeSink
        let site: MountSite

        init() {
            let sessionID = ULID()
            registry = WorkRegistry(sessionID: sessionID)
            sink = NoticeSink()
            site = MountSite(sessionID: sessionID, runPlane: RunPlane(workRegistry: registry), sink: sink)
        }

        /// Mounts `tool` on this session, as a host does at session start.
        func mount(_ tool: any Tool) {
            _ = ToolMounting.makeWrapped(tool: tool, site: site, configuration: .synchronous)
        }
    }

    @Test("a session that mounted the tool gets the notice on its session sink")
    func aMountedSessionGetsTheNotice() async {
        let board = CatalogNoticeBoard()
        let session = Session()
        session.mount(CatalogTool(catalogNoticeBoard: board))

        await board.post(Self.notice)

        #expect(session.sink.notices.values == [Self.notice])
        #expect(board.sessionIDs == [session.registry.sessionID])
    }

    @Test("a root session and its child session each get the notice one time")
    func aRootAndAChildEachGetIt() async {
        let board = CatalogNoticeBoard()
        let root = Session()
        root.mount(CatalogTool(catalogNoticeBoard: board))
        let rootContext = ToolContext(
            sessionID: root.registry.sessionID, runPlane: root.site.runPlane, sink: root.sink, tool: "agents",
            op: "start agent", completionToken: RunPlane.makeCompletionToken(), isCancelled: { false })
        let childID = ULID()
        let childSink = NoticeSink()
        let childSite = rootContext.childSite(
            sessionID: childID, runPlane: RunPlane(workRegistry: WorkRegistry(sessionID: childID)), sink: childSink)
        _ = ToolMounting.makeWrapped(tool: CatalogTool(catalogNoticeBoard: board), site: childSite, configuration: .synchronous)

        await board.post(Self.notice)

        #expect(root.sink.notices.values == [Self.notice])
        #expect(childSink.notices.values == [Self.notice])
    }

    @Test("a session that mounted the tool two times gets one notice")
    func aDoubleMountGivesOneNotice() async {
        let board = CatalogNoticeBoard()
        let session = Session()
        session.mount(CatalogTool(catalogNoticeBoard: board))
        session.mount(CatalogTool(catalogNoticeBoard: board))

        await board.post(Self.notice)

        #expect(session.sink.notices.values == [Self.notice])
    }

    @Test("a session that does not have the tool gets no notice")
    func aSessionWithNoToolGetsNone() async {
        let board = CatalogNoticeBoard()
        let other = CatalogNoticeBoard()
        let plain = Session()
        plain.mount(PlainTool())
        let onOtherBoard = Session()
        onOtherBoard.mount(CatalogTool(catalogNoticeBoard: other))

        await board.post(Self.notice)

        #expect(plain.sink.notices.values.isEmpty)
        #expect(onOtherBoard.sink.notices.values.isEmpty)
        #expect(board.sessionIDs.isEmpty)
    }

    @Test("a session leaves the board when its registry closes, and gets no later notice")
    func aClosedSessionLeavesTheBoard() async {
        let board = CatalogNoticeBoard()
        let closing = Session()
        let staying = Session()
        closing.mount(CatalogTool(catalogNoticeBoard: board))
        staying.mount(CatalogTool(catalogNoticeBoard: board))

        closing.registry.close()
        await board.post(Self.notice)

        #expect(closing.sink.notices.values.isEmpty)
        #expect(staying.sink.notices.values == [Self.notice])
        #expect(board.sessionIDs == [staying.registry.sessionID])
    }

    @Test("a session whose registry already closed never joins the board")
    func aClosedSessionNeverJoins() async {
        let board = CatalogNoticeBoard()
        let session = Session()
        session.registry.close()

        session.mount(CatalogTool(catalogNoticeBoard: board))
        await board.post(Self.notice)

        #expect(session.sink.notices.values.isEmpty)
        #expect(board.sessionIDs.isEmpty)
    }

    @Test("a session sink that is not a CatalogNoticeSink drops the notice")
    func aPlainSinkDropsTheNotice() async {
        let board = CatalogNoticeBoard()
        let sessionID = ULID()
        let sink = Fixtures.RecordingSink()
        let site = MountSite(
            sessionID: sessionID, runPlane: RunPlane(workRegistry: WorkRegistry(sessionID: sessionID)), sink: sink)
        _ = ToolMounting.makeWrapped(tool: CatalogTool(catalogNoticeBoard: board), site: site, configuration: .synchronous)

        await board.post(Self.notice)

        #expect(await sink.events.isEmpty)
        #expect(board.sessionIDs == [sessionID])
    }
}
