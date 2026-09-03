/// The three levels a health check reports, and no more (doctor-plan.md §4).
///
/// The `String` raw value is the wire vocabulary, so the `--json` doctor output
/// stays stable however the cases are later ordered or extended.
public enum HealthStatus: String, Sendable, Codable {
    /// The subject of the check works.
    case ok

    /// The subject works, and something about it needs attention.
    case warning

    /// The subject does not work.
    case error
}

/// One finding of one health check: what was checked, how it went, and — when
/// something is wrong — the action that fixes it.
///
/// A component reports these through ``Doctorable/runHealthChecks()``. The
/// three factory functions below are the ordinary way to make one, because
/// each states the fix rule of doctor-plan.md §2 at the call site:
/// ``ok(name:message:category:)`` takes no fix, and
/// ``warning(name:message:fix:category:)`` and
/// ``error(name:message:fix:category:)`` each require one.
///
/// The `Codable` conformance is synthesized on purpose. A synthesized encoder
/// writes an optional property with `encodeIfPresent`, so a `nil` ``fix`` is an
/// **absent** JSON key and never `null`. A hand-written `encode(to:)` would
/// write the `null`, so this type never states one.
public struct HealthCheck: Sendable, Equatable, Codable {
    /// What was checked, as a person reads it — "the transcripts directory".
    public let name: String

    /// How the check went.
    public let status: HealthStatus

    /// What the check found, in one sentence.
    public let message: String

    /// The command or the action that answers ``message``, or `nil` when
    /// nothing is wrong.
    ///
    /// The three factory functions make the fix rule easy to obey, and they do
    /// not make it absolute. ``init(name:status:message:fix:category:)`` stays
    /// public, and a decoder reads JSON that holds `"status": "warning"` and no
    /// `fix` key, so a ``HealthStatus/warning`` or a ``HealthStatus/error``
    /// whose fix is `nil` is a value that can exist. The doctor renderer states
    /// what it writes for that case.
    public let fix: String?

    /// Which group of checks this one belongs to — "configuration", "model".
    public let category: String

    /// Creates a finding from data the caller already holds.
    ///
    /// Prefer a factory function below, which states the fix rule at the call
    /// site. This initializer is public because a consumer builds a finding
    /// from data it already has, and a test needs to build one directly.
    ///
    /// - Parameters:
    ///   - name: What was checked.
    ///   - status: How the check went.
    ///   - message: What the check found.
    ///   - fix: The command or the action that answers `message`, or `nil`.
    ///   - category: Which group of checks this one belongs to.
    public init(name: String, status: HealthStatus, message: String, fix: String?, category: String) {
        self.name = name
        self.status = status
        self.message = message
        self.fix = fix
        self.category = category
    }

    /// A passing finding, which carries no fix because nothing is wrong.
    ///
    /// - Parameters:
    ///   - name: What was checked.
    ///   - message: What the check found.
    ///   - category: Which group of checks this one belongs to.
    /// - Returns: A finding whose status is ``HealthStatus/ok`` and whose
    ///   ``fix`` is `nil`.
    public static func ok(name: String, message: String, category: String) -> HealthCheck {
        HealthCheck(name: name, status: .ok, message: message, fix: nil, category: category)
    }

    /// A finding that needs attention, with the action that answers it.
    ///
    /// - Parameters:
    ///   - name: What was checked.
    ///   - message: What the check found.
    ///   - fix: The command or the action that answers `message`. Not optional,
    ///     so a call site cannot leave it out.
    ///   - category: Which group of checks this one belongs to.
    /// - Returns: A finding whose status is ``HealthStatus/warning``.
    public static func warning(name: String, message: String, fix: String, category: String) -> HealthCheck {
        HealthCheck(name: name, status: .warning, message: message, fix: fix, category: category)
    }

    /// A finding that reports something broken, with the action that repairs it.
    ///
    /// - Parameters:
    ///   - name: What was checked.
    ///   - message: What the check found.
    ///   - fix: The command or the action that repairs it. Not optional, so a
    ///     call site cannot leave it out.
    ///   - category: Which group of checks this one belongs to.
    /// - Returns: A finding whose status is ``HealthStatus/error``.
    public static func error(name: String, message: String, fix: String, category: String) -> HealthCheck {
        HealthCheck(name: name, status: .error, message: message, fix: fix, category: category)
    }
}
