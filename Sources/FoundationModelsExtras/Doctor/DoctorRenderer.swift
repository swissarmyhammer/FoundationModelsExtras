import Foundation

/// Draws a ``DoctorReport`` as plain text a person reads: one aligned row for
/// each finding, and a fix line under each finding that reports a problem
/// (doctor-plan.md §6).
///
/// The rendering is ASCII only. It holds no box-drawing character, and it holds
/// no terminal escape sequence, ever, so the text a pipe or a file receives is
/// stable and a test can compare it byte for byte. This is the renderer a piped
/// `doctor` uses. A decorated table is the concern of the command-line tool
/// that wants one: `doctor-plan.md` §6 states that this package must stay free
/// of a terminal dependency, because it is a library that also runs inside a
/// Mac app, so such a tool renders the ``DoctorReport`` itself.
///
/// This renderer draws the whole report. Where that report goes is the caller's
/// decision, not this type's: `doctor-plan.md` §6 sends the report to standard
/// error, because a doctor report is a diagnostic, and sends the JSON of
/// ``DoctorReport/jsonData(prettyPrinted:)`` to standard output, because a
/// script reads it. ``write(_:to:)`` therefore takes the destination as a
/// parameter.
public struct PlainTextDoctorRenderer: Sendable {
    /// Creates a renderer.
    public init() {}

    /// Draws the whole report.
    ///
    /// Each finding takes one row of three columns — the status, the name, and
    /// the message — with the first two columns padded so the rows line up. A
    /// ``HealthStatus/warning`` and a ``HealthStatus/error`` each take one more
    /// line under that row, carrying the fix. A ``HealthStatus/ok`` takes no
    /// such line, because nothing is wrong.
    ///
    /// - Parameter report: The findings to draw, in the order they are to be
    ///   read.
    /// - Returns: The rendering, with a newline closing every line. A report
    ///   that holds no finding renders as the empty string.
    public func render(_ report: DoctorReport) -> String {
        let widths = ColumnWidths(checks: report.checks)
        let lines = report.checks.flatMap { lines(for: $0, widths: widths) }
        return lines.map { "\($0)\n" }.joined()
    }

    /// Draws the report and writes it to a destination.
    ///
    /// The bytes are the plain text ``render(_:)`` returns, whatever the
    /// destination is. A terminal, a pipe and a file each receive the same
    /// rendering, so this renderer reads nothing about the handle.
    ///
    /// - Parameters:
    ///   - report: The findings to draw.
    ///   - handle: Where to write the rendering — standard error for a report a
    ///     person reads.
    /// - Throws: Whatever `FileHandle.write(contentsOf:)` throws, such as a
    ///   destination that is already closed or whose reader has gone away. The
    ///   older non-throwing `FileHandle.write(_:)` is not used, because it
    ///   reports the same failures by raising an Objective-C exception, which
    ///   Swift cannot catch.
    public func write(_ report: DoctorReport, to handle: FileHandle) throws {
        try handle.write(contentsOf: Data(render(report).utf8))
    }

    // MARK: - The words and the widths the rendering carries

    /// What stands in front of a fix line, so the line reads as belonging to
    /// the row above it.
    private static let fixIndent = "    "

    /// What opens a fix line, so a reader knows what the rest of it is.
    private static let fixLabel = "fix: "

    /// What a fix line carries for a finding that reports a problem and states
    /// no fix.
    ///
    /// ``HealthCheck/warning(name:message:fix:category:)`` and
    /// ``HealthCheck/error(name:message:fix:category:)`` each require a fix, and
    /// the memberwise initializer does not — so a decoder reading JSON that
    /// holds `"status": "error"` and no `fix` key makes exactly this value. The
    /// row still gets its line: the problem must stay visible, and a missing fix
    /// must not make a silent row.
    private static let missingFixText = "the component gave no fix"

    /// What separates two columns of a row.
    private static let columnSeparator = " "

    /// What fills the rest of a column that its text does not fill.
    private static let paddingCharacter = " "

    /// How wide each padded column of one rendering stands.
    ///
    /// The widths are read off the report rather than fixed, so a report of
    /// short names does not carry the padding a report of long ones needs.
    private struct ColumnWidths {
        /// How wide the status column stands.
        let status: Int

        /// How wide the name column stands.
        let name: Int

        /// Measures the columns a set of findings needs.
        ///
        /// A report that holds no finding gives every column a width of zero,
        /// and renders as no line at all.
        ///
        /// - Parameter checks: The findings the rendering will draw.
        init(checks: [HealthCheck]) {
            status = checks.map(\.status.rawValue.count).max() ?? 0
            name = checks.map(\.name.count).max() ?? 0
        }
    }

    // MARK: - Drawing one finding

    /// Draws one finding: its row, and the fix line the row's status calls for.
    ///
    /// - Parameters:
    ///   - check: The finding to draw.
    ///   - widths: How wide the padded columns of this rendering stand.
    /// - Returns: One line for a ``HealthStatus/ok`` finding, and two for a
    ///   finding that reports a problem.
    private func lines(for check: HealthCheck, widths: ColumnWidths) -> [String] {
        [row(for: check, widths: widths)] + fixLines(for: check)
    }

    /// Draws the row of one finding: the status, the name, and the message.
    ///
    /// - Parameters:
    ///   - check: The finding to draw.
    ///   - widths: How wide the padded columns of this rendering stand.
    /// - Returns: The row, with no closing newline.
    private func row(for check: HealthCheck, widths: ColumnWidths) -> String {
        let status = Self.padded(check.status.rawValue, to: widths.status)
        let name = Self.padded(check.name, to: widths.name)
        return [status, name, check.message].joined(separator: Self.columnSeparator)
    }

    /// Draws the fix line a finding calls for.
    ///
    /// - Parameter check: The finding to read.
    /// - Returns: No line for a ``HealthStatus/ok`` finding, and one line for a
    ///   finding that reports a problem — carrying its fix, or the statement
    ///   that it gave none.
    private func fixLines(for check: HealthCheck) -> [String] {
        switch check.status {
        case .ok:
            []
        case .warning, .error:
            ["\(Self.fixIndent)\(Self.fixLabel)\(check.fix ?? Self.missingFixText)"]
        }
    }

    /// Pads text on the right so it fills a column.
    ///
    /// - Parameters:
    ///   - text: The text to pad.
    ///   - width: How wide the column stands.
    /// - Returns: The text, followed by enough spaces to reach `width`. Text
    ///   already at least that wide is returned unchanged.
    private static func padded(_ text: String, to width: Int) -> String {
        let shortfall = max(0, width - text.count)
        return text + String(repeating: paddingCharacter, count: shortfall)
    }
}

extension DoctorReport {
    /// Encodes the findings as one JSON array, for the `--json` output of
    /// `doctor-plan.md` §6.
    ///
    /// The encoder sorts its keys, so the bytes of two runs over the same
    /// findings are the same bytes and a test can compare them exactly. A
    /// ``HealthCheck`` whose ``HealthCheck/fix`` is `nil` writes no `fix` key at
    /// all, because that type's encoder is synthesized; the key is absent rather
    /// than `null`.
    ///
    /// The report encodes itself as the array of ``checks`` (see
    /// ``encode(to:)``), because the array is what a script reads, and
    /// ``worstStatus`` and ``exitCode`` are each derived from it. The bytes
    /// decode back to an equal ``DoctorReport``, and to the same `[HealthCheck]`.
    ///
    /// - Parameter prettyPrinted: Whether to spread the array over several lines
    ///   for a person to read. The default is `false`, which is the compact form
    ///   a script wants.
    /// - Returns: The UTF-8 JSON bytes of ``checks``.
    /// - Throws: Whatever `JSONEncoder.encode` throws.
    public func jsonData(prettyPrinted: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        return try encoder.encode(self)
    }
}
