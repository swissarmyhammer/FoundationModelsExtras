@testable import FoundationModelsExtras
import Foundation
import FoundationModels
import Testing
import ULID

/// Exercises the session tree and the background work of a ``ToolContext``:
/// the root and the parent of the session of a call, the site of a child
/// session, and the lease that a tool call begins in the registry of its own
/// session.
@Suite("Tool context: the session tree and the background work of a call")
struct ToolContextWorkTests {
    private typealias Fixtures = MountFixtures

    /// The facts of the session tree that a call reads from its context.
    struct Lineage: Sendable, Equatable {
        /// The session of the call.
        let sessionID: ULID

        /// The parent session, or `nil` at the root.
        let parentSessionID: ULID?

        /// The root session.
        let rootSessionID: ULID

        /// The user presence of the root session.
        let rootUserPresence: UserPresence
    }

    /// Records the session tree of the context of each call.
    struct LineageTool: Tool {
        let name = "lineage_tool"
        let description = "records the session tree of its context"
        let seen: Recorder<Lineage>

        func call(arguments: MountArguments) async throws -> String {
            let context = try #require(ToolContext.current)
            seen.append(
                Lineage(
                    sessionID: context.sessionID, parentSessionID: context.parentSessionID,
                    rootSessionID: context.rootSessionID, rootUserPresence: context.rootUserPresence))
            return "seen"
        }
    }

    /// Begins one MCP lease, and records the open work of the session while
    /// the lease is open.
    struct LeasingTool: Tool {
        let name = "leasing_tool"
        let description = "holds an MCP lease for its call"
        let openWork: Recorder<[WorkItem]>

        func call(arguments: MountArguments) async throws -> String {
            let context = try #require(ToolContext.current)
            return await context.withBackgroundWork(.mcpCall, id: arguments.value) {
                openWork.append(context.runPlane.workRegistry.openWork)
                return "leased"
            }
        }
    }

    /// Makes a context of a new call on `runPlane` in `sessionID`.
    ///
    /// - Parameters:
    ///   - sessionID: The session of the call.
    ///   - runPlane: The run plane of the session.
    /// - Returns: The context.
    private static func context(sessionID: ULID, runPlane: RunPlane) -> ToolContext {
        ToolContext(
            sessionID: sessionID, runPlane: runPlane, sink: DiscardingOperationEventSink(), tool: "t", op: "run t",
            completionToken: RunPlane.makeCompletionToken(), isCancelled: { false })
    }

    // MARK: - The registry of the run plane

    @Test("a run plane holds the registry that the host gives, and else makes its own")
    func aRunPlaneHoldsItsRegistry() {
        let registry = WorkRegistry(sessionID: ULID())

        #expect(RunPlane(workRegistry: registry).workRegistry === registry)
        #expect(RunPlane().workRegistry !== RunPlane().workRegistry)
    }

    // MARK: - The lease of a call

    @Test("a lease that a call begins goes into the registry of its own session, with that session as owner")
    func aLeaseOfACallGoesIntoItsOwnRegistry() async {
        let sessionID = ULID()
        let registry = WorkRegistry(sessionID: sessionID)
        let otherRegistry = WorkRegistry(sessionID: ULID())
        let context = Self.context(sessionID: sessionID, runPlane: RunPlane(workRegistry: registry))
        _ = RunPlane(workRegistry: otherRegistry)

        let lease = context.beginBackgroundWork(.mcpCall, id: "call-1")

        #expect(lease.sessionID == sessionID)
        #expect(registry.openWork == [WorkItem(kind: .mcpCall, id: "call-1", sessionID: sessionID)])
        #expect(otherRegistry.openWork.isEmpty)
        lease.end()
        #expect(!registry.hasWork)
    }

    @Test("withBackgroundWork in a mounted call holds the session busy for the body, then ends")
    func withBackgroundWorkInAMountedCall() async throws {
        let sessionID = ULID()
        let registry = WorkRegistry(sessionID: sessionID)
        let runPlane = RunPlane(workRegistry: registry)
        let openWork = Recorder<[WorkItem]>()
        let site = MountSite(sessionID: sessionID, runPlane: runPlane, sink: Fixtures.RecordingSink())
        let mounted = RunToCompletionRunner(wrapping: LeasingTool(openWork: openWork), site: site, timeout: nil)

        _ = try await mounted.call(arguments: MountArguments(value: "call-2"))

        #expect(openWork.values == [[WorkItem(kind: .mcpCall, id: "call-2", sessionID: sessionID)]])
        #expect(!registry.hasWork)
    }

    // MARK: - The session tree

    @Test("at the root, the root is the session itself and the parent is nil")
    func theRootIsItsOwnRoot() async throws {
        let sessionID = ULID()
        let context = Self.context(sessionID: sessionID, runPlane: RunPlane(userPresence: .headless))

        #expect(context.rootSessionID == sessionID)
        #expect(context.parentSessionID == nil)
        #expect(context.rootUserPresence == .headless)
    }

    @Test("a call in a child session sees its parent, the root, and the user presence of the root")
    func aChildCallSeesItsParentAndTheRoot() async throws {
        let rootID = ULID()
        let childID = ULID()
        let grandchildID = ULID()
        let rootPlane = RunPlane(userPresence: .interactive)
        let childPlane = RunPlane(userPresence: .headless)
        let seen = Recorder<Lineage>()
        let rootContext = Self.context(sessionID: rootID, runPlane: rootPlane)

        let childSite = rootContext.childSite(sessionID: childID, runPlane: childPlane, sink: Fixtures.RecordingSink())
        let child = RunToCompletionRunner(wrapping: LineageTool(seen: seen), site: childSite, timeout: nil)
        _ = try await child.call(arguments: MountArguments(value: "x"))
        let grandchildSite = childSite.childSite(
            sessionID: grandchildID, runPlane: RunPlane(userPresence: .headless), sink: Fixtures.RecordingSink())
        let grandchild = RunToCompletionRunner(wrapping: LineageTool(seen: seen), site: grandchildSite, timeout: nil)
        _ = try await grandchild.call(arguments: MountArguments(value: "x"))

        #expect(
            seen.values == [
                Lineage(sessionID: childID, parentSessionID: rootID, rootSessionID: rootID, rootUserPresence: .interactive),
                Lineage(
                    sessionID: grandchildID, parentSessionID: childID, rootSessionID: rootID,
                    rootUserPresence: .interactive),
            ])
    }

    @Test("a lease of a child session goes into the registry of the child, never of the parent")
    func aChildLeaseStaysInTheChild() async throws {
        let rootRegistry = WorkRegistry(sessionID: ULID())
        let childID = ULID()
        let childRegistry = WorkRegistry(sessionID: childID)
        let rootContext = Self.context(sessionID: rootRegistry.sessionID, runPlane: RunPlane(workRegistry: rootRegistry))
        let openWork = Recorder<[WorkItem]>()
        let childSite = rootContext.childSite(
            sessionID: childID, runPlane: RunPlane(workRegistry: childRegistry), sink: Fixtures.RecordingSink())
        let child = RunToCompletionRunner(wrapping: LeasingTool(openWork: openWork), site: childSite, timeout: nil)

        let agentsLease = rootContext.beginBackgroundWork(.childSession, id: childID.ulidString)
        _ = try await child.call(arguments: MountArguments(value: "in-child"))

        #expect(openWork.values == [[WorkItem(kind: .mcpCall, id: "in-child", sessionID: childID)]])
        #expect(rootRegistry.openWork == [WorkItem(kind: .childSession, id: childID.ulidString, sessionID: rootRegistry.sessionID)])
        agentsLease.end()
        #expect(!rootRegistry.hasWork)
    }
}
