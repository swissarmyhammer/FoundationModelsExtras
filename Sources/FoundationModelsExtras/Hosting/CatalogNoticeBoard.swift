import FoundationModels
import Synchronization
import ULID

/// A tool that lists a catalog in its description, and posts each change of
/// that catalog through ``catalogNoticeBoard``.
///
/// When a host mounts the tool on a session with
/// ``ToolMounting/makeWrapped(tool:site:configuration:)``, the session joins
/// the board. A root session and a child session mount their tools in the
/// same way, so both join.
public protocol CatalogNoticing {
    /// The board that the tool package posts each change of the catalog to.
    var catalogNoticeBoard: CatalogNoticeBoard { get }
}

/// The live sessions that mounted a ``CatalogNoticing`` tool, and the post of
/// a ``CatalogChangeNotice`` to each of them.
///
/// A tool package makes one board for each catalog, and gives it to each
/// tool that it makes. When the catalog reloads, the package compares the old
/// and the new catalog with ``CatalogChangeNotice/init(kind:from:to:)`` and
/// calls ``post(_:)``. The description of a tool never changes during a
/// session, thus the notice is how a session learns of the change.
///
/// A session joins the board when it mounts the tool, one time, also when it
/// mounts the tool two times. It leaves the board when its ``WorkRegistry``
/// closes. A session that mounts the tool after its registry closed never
/// joins.
public final class CatalogNoticeBoard: Sendable {
    /// The session sink of each live session that joined, by its session id,
    /// and the join order.
    private struct State {
        /// The session sink of each session.
        var sinks: [ULID: any OperationEventSink] = [:]

        /// The session ids, in join order.
        var order: [ULID] = []
    }

    /// The state of this board.
    private let state = Mutex(State())

    /// Makes an empty board.
    public init() {}

    /// The id of each live session that joined, in join order.
    public var sessionIDs: [ULID] {
        state.withLock(\.order)
    }

    /// Sends `notice` to the session sink of each live session that joined,
    /// in join order, and returns when each sink took it. A sink that is not
    /// a ``CatalogNoticeSink`` drops it.
    ///
    /// - Parameter notice: The notice.
    public func post(_ notice: CatalogChangeNotice) async {
        let sinks = state.withLock { state in state.order.compactMap { state.sinks[$0] } }
        for sink in sinks {
            await (sink as? any CatalogNoticeSink)?.post(catalogNotice: notice)
        }
    }

    /// Joins the session of `site`, with its session sink, until the
    /// registry of the session closes. A session that already joined keeps
    /// its first sink.
    ///
    /// - Parameter site: The mount site of the session.
    func join(_ site: MountSite) {
        let sessionID = site.sessionID
        let sink = site.sessionSink
        let joined = state.withLock { state in
            guard state.sinks[sessionID] == nil else { return false }
            state.sinks[sessionID] = sink
            state.order.append(sessionID)
            return true
        }
        guard joined else { return }
        site.runPlane.workRegistry.whenClosed { [weak self] in
            self?.leave(sessionID)
        }
    }

    /// Forgets the session `sessionID`.
    ///
    /// - Parameter sessionID: The session.
    private func leave(_ sessionID: ULID) {
        state.withLock { state in
            state.sinks[sessionID] = nil
            state.order.removeAll { $0 == sessionID }
        }
    }
}
