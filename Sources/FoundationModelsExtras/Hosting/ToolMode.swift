import Foundation
import Security

/// The mode in which a package composes the tools that it gives to a
/// session.
///
/// The JSON form of a mode is a plain string: its raw value.
public enum ToolMode: String, Sendable, Codable, CaseIterable {
    /// The package registers all of its tools. Some of these tools cannot
    /// work in the App Sandbox.
    case open

    /// The package registers only the tools that work in the App Sandbox. A
    /// package does not register a tool that cannot work in the App Sandbox
    /// in this mode.
    case sandboxed
}

extension ToolMode {
    /// Makes sure that this mode can work in the current process.
    ///
    /// Each package calls this one function when it composes its tools,
    /// before it registers a tool. Thus a wrong mode fails at composition
    /// time, not at the first tool call.
    ///
    /// - Parameter probe: The probe that tells if the process is sandboxed.
    ///   The default reads the current process.
    /// - Throws: ``ToolModeError/openModeInSandbox`` when the mode is
    ///   ``open`` and the process is sandboxed. The function does not throw
    ///   in the other three cases.
    public func validate(probe: SandboxProbe = .live) throws(ToolModeError) {
        guard self == .open, probe.isSandboxed() else { return }
        throw .openModeInSandbox
    }
}

/// Tells if the current process is sandboxed.
///
/// ``live`` reads the current process. A test gives ``fixed(_:)`` to fake a
/// sandboxed process.
public struct SandboxProbe: Sendable {
    /// The entitlement that turns on the App Sandbox.
    private static let sandboxEntitlement = "com.apple.security.app-sandbox"

    /// The environment variable that the system sets for a sandboxed process.
    private static let sandboxContainerVariable = "APP_SANDBOX_CONTAINER_ID"

    /// Gives `true` when the process is sandboxed.
    public let isSandboxed: @Sendable () -> Bool

    /// Makes a probe from a closure.
    ///
    /// - Parameter isSandboxed: Gives `true` when the process is sandboxed.
    public init(isSandboxed: @escaping @Sendable () -> Bool) {
        self.isSandboxed = isSandboxed
    }

    /// The probe of the current process.
    ///
    /// It reads the `com.apple.security.app-sandbox` entitlement of the
    /// process. When the entitlement cannot be read, it reads the
    /// `APP_SANDBOX_CONTAINER_ID` environment variable.
    public static let live = SandboxProbe {
        entitlementValue() ?? environmentHasContainer()
    }

    /// Makes a probe that always gives `value`.
    ///
    /// - Parameter value: The value that the probe gives.
    /// - Returns: A probe that gives `value`.
    public static func fixed(_ value: Bool) -> SandboxProbe {
        SandboxProbe { value }
    }

    /// Reads the sandbox entitlement of the current process.
    ///
    /// - Returns: The value of the entitlement, `false` when the process does
    ///   not have it, or `nil` when the entitlement cannot be read.
    private static func entitlementValue() -> Bool? {
        guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault) else { return nil }
        var error: Unmanaged<CFError>?
        let value = SecTaskCopyValueForEntitlement(task, sandboxEntitlement as CFString, &error)
        if let error {
            _ = error.takeRetainedValue()
            return nil
        }
        return (value as? Bool) ?? false
    }

    /// Tells if the environment names a sandbox container.
    ///
    /// - Returns: `true` when the environment has the container variable.
    private static func environmentHasContainer() -> Bool {
        ProcessInfo.processInfo.environment[sandboxContainerVariable] != nil
    }
}

/// An error of ``ToolMode/validate(probe:)``.
public enum ToolModeError: Error, Equatable, Sendable, LocalizedError {
    /// The mode is ``ToolMode/open`` and the process is sandboxed. Some tools
    /// of the open mode cannot work in the App Sandbox.
    case openModeInSandbox

    /// A message that tells what is wrong.
    public var errorDescription: String? {
        switch self {
        case .openModeInSandbox:
            return "The tool mode is open, and this process is in the App Sandbox. "
                + "Some tools of the open mode cannot work in the App Sandbox. "
                + "Use the \(ToolMode.sandboxed.rawValue) mode."
        }
    }
}
