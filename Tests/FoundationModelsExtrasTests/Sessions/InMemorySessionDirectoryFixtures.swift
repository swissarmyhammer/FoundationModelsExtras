import Foundation
@testable import FoundationModelsExtras
import ULID

/// Values, directories and helpers that the tests of
/// ``InMemorySessionDirectory`` share.
enum InMemorySessionDirectoryFixtures {
    /// The id of the agent that the tests start most of the time.
    static let reviewerAgentID = "reviewer"

    /// The agent ids that the fake launcher knows.
    static let knownAgentIDs = [reviewerAgentID, "builder", "planner"]

    /// The folder that a start with no folder and no starter gets.
    static let defaultFolder = URL(fileURLWithPath: "/tmp/agents", isDirectory: true)

    /// The working folder of the sessions that the tests start.
    static let projectFolder = URL(fileURLWithPath: "/tmp/project", isDirectory: true)

    /// An other working folder, which no session uses until a test starts one
    /// there.
    static let otherFolder = URL(fileURLWithPath: "/tmp/other", isDirectory: true)

    /// The client id of the UI that the tests send from.
    static let clientID = "testudo-window-1"

    /// A UI sender.
    static let user = SessionMessageSender.user(clientID: clientID)

    /// The fixed time that the directory stamps on each change.
    static let now = SessionFixtures.createdAt

    /// The fake launcher of the tests.
    static let launcher = InMemorySessionDirectory.Launcher(
        agentIDs: knownAgentIDs, defaultWorkingDirectory: defaultFolder)

    /// Makes a directory with the fake launcher and a fixed clock.
    ///
    /// - Parameter loopGuards: The loop guards. The default is the default
    ///   guards of session.md section 10.3.
    /// - Returns: A new, empty directory.
    static func makeDirectory(
        loopGuards: InMemorySessionDirectory.LoopGuards = InMemorySessionDirectory.LoopGuards()
    ) -> InMemorySessionDirectory {
        InMemorySessionDirectory(launcher: launcher, loopGuards: loopGuards, now: { now })
    }

    /// Starts a session of the reviewer agent in the project folder. The
    /// first message starts a turn, thus the session works.
    ///
    /// - Parameters:
    ///   - directory: The directory to start it in.
    ///   - tags: The tags of the session. The default is none.
    ///   - startedBy: The session that starts it. The default is none.
    /// - Returns: The summary of the new session.
    static func startWorkingSession(
        in directory: InMemorySessionDirectory,
        tags: Set<String> = [],
        startedBy: ULID? = nil
    ) async throws -> SessionSummary {
        try await directory.start(
            SessionStartRequest(
                agentID: reviewerAgentID,
                workingDirectory: projectFolder,
                firstMessage: "Review the change.",
                tags: tags,
                startedBy: startedBy,
                origin: .tool))
    }

    /// Starts a session and ends its first turn, thus the session is idle.
    ///
    /// - Parameters:
    ///   - directory: The directory to start it in.
    ///   - tags: The tags of the session. The default is none.
    /// - Returns: The id of the idle session.
    static func startIdleSession(
        in directory: InMemorySessionDirectory,
        tags: Set<String> = []
    ) async throws -> ULID {
        let id = try await startWorkingSession(in: directory, tags: tags).id
        try directory.finishTurn(of: id, lastSummary: "Done.")
        return id
    }

    /// Ends each event stream of the directory, then reads every event that
    /// `stream` holds. The read needs no clock: the streams end at once.
    ///
    /// - Parameters:
    ///   - stream: A stream from ``InMemorySessionDirectory/events()``.
    ///   - directory: The directory of the stream.
    /// - Returns: The events of the stream, in order.
    static func drain(
        _ stream: AsyncStream<SessionDirectoryEvent>,
        of directory: InMemorySessionDirectory
    ) async -> [SessionDirectoryEvent] {
        directory.finishEventStreams()
        return await stream.reduce(into: []) { events, event in events.append(event) }
    }
}

extension Sequence {
    /// Maps each element with an async call, one after the other, in order.
    ///
    /// - Parameter transform: The async call.
    /// - Returns: The results, in order.
    func asyncMap<Result>(_ transform: (Element) async throws -> Result) async rethrows -> [Result] {
        var results: [Result] = []
        for element in self {
            results.append(try await transform(element))
        }
        return results
    }
}
