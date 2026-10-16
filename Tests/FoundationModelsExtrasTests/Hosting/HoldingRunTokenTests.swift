import Foundation
import FoundationModels
import FoundationModelsExtras
import Testing
import ULID

/// Exercises ``ToolContext/holdingRunToken``: the value that tells a host
/// which run holds a context, so that the host can group the inner calls of
/// one run.
///
/// The import is plain, with no `@testable`. When the member loses `public`,
/// this file does not compile. Each tool returns the values that it read, and
/// each test calls the tools in a fixed order. No test reads a clock, sleeps,
/// polls or retries.
@Suite("ToolContext: the run that holds a context")
struct HoldingRunTokenTests {
    /// The settle period of the background inner call, in seconds. The call
    /// returns at once, so its run settles in this time and the call gives
    /// its output.
    private static let backgroundGraceSeconds: TimeInterval = 3600

    /// The arguments of each tool of this suite.
    @Generable
    struct ProbeArguments {
        /// A value that the tools do not read.
        let value: String
    }

    /// The two tokens that one context gives.
    private struct Tokens: Equatable {
        /// ``ToolContext/holdingRunToken`` of the context.
        let holding: String

        /// ``ToolContext/completionToken`` of the context.
        let completion: String

        /// The tokens of `context`.
        ///
        /// - Parameter context: The context.
        init(of context: ToolContext) {
            holding = context.holdingRunToken
            completion = context.completionToken
        }

        /// The tokens that ``line`` wrote.
        ///
        /// - Parameter line: One line of the output of a tool.
        /// - Throws: A failed expectation when the line does not hold two
        ///   tokens.
        init(line: Substring) throws {
            let parts = line.split(separator: " ")
            try #require(parts.count == 2)
            holding = String(parts[0])
            completion = String(parts[1])
        }

        /// The tokens as one line of the output of a tool.
        var line: String {
            "\(holding) \(completion)"
        }
    }

    /// The tokens that the run of a ``RunTool`` and each of its inner calls
    /// gave, in call order.
    private struct RunReport {
        /// The context of the run.
        let run: Tokens

        /// The first and the second synchronous inner call.
        let firstInner: Tokens
        let secondInner: Tokens

        /// The synchronous call that a synchronous inner call mounted.
        let nested: Tokens

        /// The background inner call.
        let background: Tokens

        /// Reads the output of a ``RunTool``.
        ///
        /// - Parameter output: The output, one line for each context.
        /// - Throws: A failed expectation when the output does not hold five
        ///   lines of tokens.
        init(output: String) throws {
            let lines = try output.split(separator: "\n").map(Tokens.init(line:))
            try #require(lines.count == 5)
            run = lines[0]
            firstInner = lines[1]
            secondInner = lines[2]
            nested = lines[3]
            background = lines[4]
        }
    }

    /// Returns the tokens of its own context.
    private struct ReportTool: Tool {
        let name = "report_tool"
        let description = "returns the tokens of its context"

        func call(arguments: ProbeArguments) async throws -> String {
            try Tokens(of: #require(ToolContext.current)).line
        }
    }

    /// Mounts a ``ReportTool`` synchronously, calls it, and returns its
    /// output.
    private struct NestingTool: Tool {
        let name = "nesting_tool"
        let description = "calls a synchronous inner tool"

        func call(arguments: ProbeArguments) async throws -> String {
            let context = try #require(ToolContext.current)
            return try await context.mount(ReportTool()).call(arguments: arguments)
        }
    }

    /// Declares a background mount with a long settle period, and returns the
    /// tokens of its own context at once.
    private struct BackgroundReportTool: Tool, BackgroundTool {
        let name = "background_report_tool"
        let description = "returns the tokens of its background run"

        var mount: ToolMount? { ToolMount(mode: .background) }

        var inlineSettleGrace: TimeInterval { HoldingRunTokenTests.backgroundGraceSeconds }

        func call(arguments: ProbeArguments) async throws -> String {
            try Tokens(of: #require(ToolContext.current)).line
        }
    }

    /// A run with inner calls, as a script runner makes them. It returns one
    /// line of tokens for its own context, then one line for each inner call,
    /// in this order: two synchronous calls, a synchronous call that makes a
    /// synchronous call, and a background call.
    private struct RunTool: Tool {
        let name = "run_tool"
        let description = "makes inner calls and returns their tokens"

        func call(arguments: ProbeArguments) async throws -> String {
            let context = try #require(ToolContext.current)
            let report = context.mount(ReportTool())
            var lines = [Tokens(of: context).line]
            lines.append(try await report.call(arguments: arguments))
            lines.append(try await report.call(arguments: arguments))
            lines.append(try await context.mount(NestingTool()).call(arguments: arguments))
            lines.append(try await context.mount(BackgroundReportTool()).call(arguments: arguments))
            return lines.joined(separator: "\n")
        }
    }

    /// ``RunTool`` as a host mounts it on a session: a synchronous call that
    /// no run holds.
    ///
    /// - Parameter runPlane: The run plane of the session.
    /// - Returns: The mounted tool.
    /// - Throws: A failed expectation when the mount changes the types.
    private static func mountedRun(on runPlane: RunPlane) throws -> any Tool<ProbeArguments, String> {
        let site = MountSite(sessionID: ULID(), runPlane: runPlane, sink: PublicSurfaceRecordingSink())
        let mounted = ToolMounting.makeWrapped(tool: RunTool(), site: site, configuration: .synchronous)
        return try #require(mounted as? any Tool<ProbeArguments, String>)
    }

    /// Calls a mounted ``RunTool`` one time.
    ///
    /// - Parameter run: The mounted tool.
    /// - Returns: The tokens of the run and of its inner calls.
    /// - Throws: The error of the call, or a failed expectation.
    private static func report(of run: any Tool<ProbeArguments, String>) async throws -> RunReport {
        try RunReport(output: await run.call(arguments: ProbeArguments(value: "run")))
    }

    @Test("the context of a run gives its own completion token")
    func aRunGivesItsOwnToken() async throws {
        let report = try await Self.report(of: Self.mountedRun(on: RunPlane()))

        #expect(report.run.holding == report.run.completion)
    }

    @Test("two synchronous inner calls of one run give the token of that run, and each has its own completion token")
    func synchronousInnerCallsGiveTheRunToken() async throws {
        let report = try await Self.report(of: Self.mountedRun(on: RunPlane()))

        #expect(report.firstInner.holding == report.run.completion)
        #expect(report.secondInner.holding == report.run.completion)
        #expect(report.firstInner.completion != report.secondInner.completion)
        #expect(report.firstInner.completion != report.run.completion)
    }

    @Test("a synchronous call that a synchronous inner call mounts gives the token of the run")
    func aNestedSynchronousCallGivesTheRunToken() async throws {
        let report = try await Self.report(of: Self.mountedRun(on: RunPlane()))

        #expect(report.nested.holding == report.run.completion)
        #expect(report.nested.completion != report.run.completion)
    }

    @Test("a background inner call is a run of its own and gives its own completion token")
    func aBackgroundInnerCallGivesItsOwnToken() async throws {
        let report = try await Self.report(of: Self.mountedRun(on: RunPlane()))

        #expect(report.background.holding == report.background.completion)
        #expect(report.background.holding != report.run.completion)
    }

    @Test("two runs on one session give different values, and the inner calls of each run give the value of that run")
    func twoRunsGiveDifferentValues() async throws {
        let run = try Self.mountedRun(on: RunPlane())

        let first = try await Self.report(of: run)
        let second = try await Self.report(of: run)

        #expect(first.run.holding != second.run.holding)
        #expect(first.firstInner.holding == first.run.holding)
        #expect(second.firstInner.holding == second.run.holding)
        #expect(first.firstInner.holding != second.firstInner.holding)
    }

    @Test("a context that a host makes with the public init gives its own completion token, and its synchronous calls give it too")
    func aHostContextGivesItsOwnToken() async throws {
        let token = ToolContext.makeCompletionToken()
        let context = ToolContext(
            sessionID: ULID(), runPlane: RunPlane(), sink: PublicSurfaceRecordingSink(), tool: "host",
            op: "run model", completionToken: token, isCancelled: { false })

        let output = try await context.mount(ReportTool()).call(arguments: ProbeArguments(value: "x"))
        let inner = try Tokens(line: Substring(output))

        #expect(context.holdingRunToken == token)
        #expect(inner.holding == token)
        #expect(inner.completion != token)
    }
}
