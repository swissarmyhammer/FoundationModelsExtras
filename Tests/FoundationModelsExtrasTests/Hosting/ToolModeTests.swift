import Foundation
import FoundationModelsExtras
import Testing

/// Holds the behavior of ``ToolMode``, ``SandboxProbe`` and
/// ``ToolModeError``: the two values, their JSON form, and the check that
/// refuses the open mode in the App Sandbox.
@Suite("ToolMode")
struct ToolModeTests {
    /// Each mode with its raw value.
    private static let rawValues: [(ToolMode, String)] = [
        (.open, "open"),
        (.sandboxed, "sandboxed"),
    ]

    /// Each pair of mode and probe value that the check accepts.
    private static let acceptedPairs: [(ToolMode, Bool)] = [
        (.open, false),
        (.sandboxed, true),
        (.sandboxed, false),
    ]

    /// Encodes `mode` to JSON text.
    ///
    /// - Parameter mode: The mode to encode.
    /// - Returns: The JSON text of `mode`.
    private static func jsonText(of mode: ToolMode) throws -> String {
        String(decoding: try JSONEncoder().encode(mode), as: UTF8.self)
    }

    // MARK: - The values

    @Test("the modes are open and sandboxed, in that order")
    func theModesAreOpenAndSandboxed() {
        #expect(ToolMode.allCases == [.open, .sandboxed])
    }

    @Test("each mode has its name as its raw value", arguments: rawValues)
    func eachModeHasItsNameAsItsRawValue(mode: ToolMode, rawValue: String) {
        #expect(mode.rawValue == rawValue)
    }

    // MARK: - The JSON form

    @Test("the JSON form of the sandboxed mode is a plain string")
    func theJSONFormOfSandboxedIsAPlainString() throws {
        #expect(try Self.jsonText(of: .sandboxed) == "\"sandboxed\"")
    }

    @Test("each mode decodes from its own JSON form", arguments: ToolMode.allCases)
    func eachModeDecodesFromItsOwnJSONForm(mode: ToolMode) throws {
        let data = try JSONEncoder().encode(mode)

        #expect(try JSONDecoder().decode(ToolMode.self, from: data) == mode)
    }

    @Test("a string that names no mode does not decode")
    func anUnknownStringDoesNotDecode() {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ToolMode.self, from: Data("\"unsafe\"".utf8))
        }
    }

    // MARK: - The check

    @Test("the open mode in a sandboxed process fails the check")
    func theOpenModeInASandboxFailsTheCheck() {
        #expect(throws: ToolModeError.openModeInSandbox) {
            try ToolMode.open.validate(probe: .fixed(true))
        }
    }

    @Test("the check accepts each other pair of mode and process", arguments: acceptedPairs)
    func theCheckAcceptsEachOtherPair(mode: ToolMode, isSandboxed: Bool) {
        #expect(throws: Never.self) {
            try mode.validate(probe: .fixed(isSandboxed))
        }
    }

    @Test("the message of the error names the sandboxed mode")
    func theMessageOfTheErrorNamesTheSandboxedMode() throws {
        let message = try #require(ToolModeError.openModeInSandbox.errorDescription)

        #expect(message.contains(ToolMode.sandboxed.rawValue))
    }

    // MARK: - The probe

    @Test("the live probe finds no sandbox in the test process")
    func theLiveProbeFindsNoSandbox() {
        #expect(!SandboxProbe.live.isSandboxed())
    }

    @Test("a fixed probe gives its own value", arguments: [true, false])
    func aFixedProbeGivesItsOwnValue(value: Bool) {
        #expect(SandboxProbe.fixed(value).isSandboxed() == value)
    }
}
