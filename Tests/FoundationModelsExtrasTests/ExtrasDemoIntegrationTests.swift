// `ExtrasDemoIntegrationTests` — the living contract test for
// `Examples/ExtrasDemo` (plan.md §7): launches the built `extras-demo`
// executable as a subprocess (mirrors `FoundationModelsShelltool`'s
// `ExampleIntegrationTests`) and asserts on its stdout/exit codes for every
// acceptance criterion on the `Examples/ExtrasDemo` kanban task.
//
// Deliberately a plain `import FoundationModelsExtras` with no `@testable`:
// the point of this suite is to prove the example's own construction path —
// a consumer with only the public surface — round-trips end to end.

import Foundation
import Testing

@Suite struct ExtrasDemoIntegrationTests {

    // MARK: - Locating the built binary and fixtures

    /// The built `extras-demo` executable, located next to the running test
    /// bundle (SwiftPM places both under `.build/<config>/`). Declared as a
    /// dependency of the test target, so `swift test` builds it first.
    ///
    /// Mirrors `FoundationModelsShelltool`'s `ExampleIntegrationTests.shellDemoBinary()`.
    private static func extrasDemoBinary() throws -> URL {
        var candidates: [URL] = []
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            candidates.append(bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("extras-demo"))
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        candidates.append(cwd.appendingPathComponent(".build/debug/extras-demo"))
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw BinaryNotFoundError(candidates: candidates)
        }
        return binary
    }

    /// Raised by the subprocess harness itself when no built binary is found.
    private struct BinaryNotFoundError: Error, CustomStringConvertible {
        let candidates: [URL]
        var description: String { "extras-demo binary not found among: \(candidates.map(\.path))" }
    }

    /// The checked-in `Examples/ExtrasDemo/Fixtures/` tree, resolved relative
    /// to the package root (this test file lives under
    /// `Tests/FoundationModelsExtrasTests/`, three levels below it).
    private static let fixturesRoot =
        PackageRootValidation.packageRoot()
        .appendingPathComponent("Examples/ExtrasDemo/Fixtures", isDirectory: true)

    // MARK: - Subprocess harness

    /// The result of running `extras-demo`: its combined output and exit code.
    private struct RunResult {
        let output: String
        let exitCode: Int32
    }

    /// Launches the built `extras-demo` executable with `arguments`, in a
    /// fresh temp working directory (so the run cannot depend on the
    /// process's cwd, and can never write into the repo), and collects its
    /// combined output and exit code.
    private static func run(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> RunResult {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("extrasdemo-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let process = Process()
        process.executableURL = try extrasDemoBinary()
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return RunResult(output: String(decoding: data, as: UTF8.self), exitCode: process.terminationStatus)
    }

    // MARK: - `stack`: source tracking and the EXTRASDEMO_DEFAULTS_DIR override

    @Test func stackReportsWhichLayerWonEachItem() throws {
        let result = try Self.run(["stack"])

        #expect(result.exitCode == 0)
        #expect(result.output.contains("config.yaml -> project"))
        #expect(result.output.contains("hello -> defaults"))
        #expect(result.output.contains("status -> user"))
        #expect(result.output.contains("ps -> project"))
    }

    @Test func stackAnswersChangeWhenDefaultsDirectoryIsRepointedViaEnvVarWithNoRebuild() throws {
        var environment = ProcessInfo.processInfo.environment
        environment["EXTRASDEMO_DEFAULTS_DIR"] = Self.fixturesRoot.appendingPathComponent("user").path

        let result = try Self.run(["stack"], environment: environment)

        #expect(result.exitCode == 0)
        // The user fixture (now standing in for defaults too) has no
        // "hello" command, so it disappears from the enumeration entirely —
        // the same binary, no rebuild, a different defaults directory.
        #expect(!result.output.contains("hello"))
        #expect(result.output.contains("ps -> project"))
    }

    // MARK: - `render`: context variable, env variable, well-known value, partial include

    @Test func renderShowsContextVariableEnvVariableWellKnownValueAndLayeredPartialInclude() throws {
        let goodFixture = Self.fixturesRoot.appendingPathComponent("render/good.md").path

        let result = try Self.run(["render", goodFixture, "--set", "name=World"])

        #expect(result.exitCode == 0)
        #expect(result.output.contains("name=World"))
        #expect(result.output.contains("env_home="))
        #expect(result.output.contains("working_directory="))
        // The project fixture's `_partials/header.md` shadows the user
        // one — nearest-wins across the layered partials.
        #expect(result.output.contains("project header"))
    }

    // MARK: - `render --untrusted`: the trust split

    @Test func renderOfTheBadFixtureSucceedsTrustedButIsRejectedUntrusted() throws {
        let badFixture = Self.fixturesRoot.appendingPathComponent("render/bad.md").path

        let trusted = try Self.run(["render", badFixture])
        #expect(trusted.exitCode == 0)

        let untrusted = try Self.run(["render", badFixture, "--untrusted"])
        #expect(untrusted.exitCode != 0)
        #expect(untrusted.output.lowercased().contains("now"))
    }

    // MARK: - `commands`: prompt expansion, streamed action lines, commandUpdates

    @Test func commandsShowsPromptExpansionStreamedActionLinesAndTheUpdatedSet() throws {
        let result = try Self.run(["commands"])

        #expect(result.exitCode == 0)
        #expect(result.output.contains("prompt 'greet' rendered: Hello World!"))
        #expect(result.output.contains("action 'stream' line: line 1 for demo-arg"))
        #expect(result.output.contains("action 'stream' line: line 2 for demo-arg"))
        #expect(result.output.contains("action 'stream' line: line 3 for demo-arg"))
        #expect(result.output.contains("commandUpdates republished: greet, stream, status"))
    }
}
