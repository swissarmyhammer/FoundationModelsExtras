import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// The escape sequences the colored doctor output writes, named for what each
/// one says about a finding rather than for the color it paints.
///
/// These are ANSI select-graphic-rendition sequences, which every terminal
/// emulator reads and no file or pipe should ever receive. Each one opens with
/// the escape character `0x1B`, which is the byte a test counts to tell a
/// colored rendering from a plain one.
///
/// The sequences are written out here rather than pulled from a terminal
/// package, because `doctor-plan.md` §6 states that this package must stay free
/// of a terminal dependency: it is a library that also runs inside a Mac app. A
/// command-line tool that wants a decorated table renders the ``DoctorReport``
/// itself.
private enum TerminalStyle {
    /// Returns the terminal to its default appearance.
    static let reset = "\u{001B}[0m"

    /// Green, for a finding whose subject works.
    static let passing = "\u{001B}[32m"

    /// Yellow, for a finding that needs attention.
    static let attention = "\u{001B}[33m"

    /// Red, for a finding whose subject does not work.
    static let broken = "\u{001B}[31m"
}

/// Draws a ``DoctorReport`` as plain text a person reads: one aligned row for
/// each finding, and a fix line under each finding that reports a problem
/// (doctor-plan.md §6).
///
/// The rendering is ASCII only. It holds no box-drawing character, and it holds
/// an ANSI escape only when ``useColor`` is `true`, so the text a pipe receives
/// is stable and a test can compare it byte for byte.
///
/// This renderer draws the whole report. Where that report goes is the caller's
/// decision, not this type's: `doctor-plan.md` §6 sends the report to standard
/// error, because a doctor report is a diagnostic, and sends the JSON of
/// ``DoctorReport/jsonData(prettyPrinted:)`` to standard output, because a
/// script reads it. ``write(_:to:)`` therefore takes the destination as a
/// parameter.
public struct PlainTextDoctorRenderer: Sendable {
    /// Whether ``render(_:)`` wraps each status word in an ANSI color escape.
    ///
    /// ``write(_:to:)`` does not read this property. It reads the destination
    /// instead, because only the destination knows whether anything can display
    /// a color.
    public let useColor: Bool

    /// Creates a renderer.
    ///
    /// - Parameter useColor: Whether ``render(_:)`` writes ANSI color escapes.
    ///   The default is `false`, which is the form a file, a pipe and a test
    ///   each want.
    public init(useColor: Bool = false) {
        self.useColor = useColor
    }

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

    /// Draws the report and writes it to a destination, in color only when that
    /// destination is a terminal.
    ///
    /// The color decision is made here rather than by the caller, so the
    /// terminal test lives in this library once instead of in each command-line
    /// tool. ``useColor`` is not consulted: a pipe gets plain text however this
    /// renderer was built.
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
        let destinationIsTerminal = isatty(handle.fileDescriptor) == Self.isattyTrue
        let rendering = PlainTextDoctorRenderer(useColor: destinationIsTerminal).render(report)
        try handle.write(contentsOf: Data(rendering.utf8))
    }

    // MARK: - The words and the widths the rendering carries

    /// What `isatty` answers for a file descriptor that is a terminal.
    private static let isattyTrue: Int32 = 1

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
    /// The status is padded before it is colored, so the escape sequences never
    /// enter the width the padding counts and the columns line up in both
    /// renderings.
    ///
    /// - Parameters:
    ///   - check: The finding to draw.
    ///   - widths: How wide the padded columns of this rendering stand.
    /// - Returns: The row, with no closing newline.
    private func row(for check: HealthCheck, widths: ColumnWidths) -> String {
        let status = colored(
            Self.padded(check.status.rawValue, to: widths.status), for: check.status)
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

    /// Wraps text in the color of a status, when this renderer writes color.
    ///
    /// - Parameters:
    ///   - text: The text to wrap.
    ///   - status: The status whose color to use.
    /// - Returns: The text unchanged when ``useColor`` is `false`, and the text
    ///   between the status color and the reset sequence when it is `true`.
    private func colored(_ text: String, for status: HealthStatus) -> String {
        guard useColor else { return text }
        return "\(Self.style(for: status))\(text)\(TerminalStyle.reset)"
    }

    /// The escape sequence that paints a status.
    ///
    /// - Parameter status: The status to paint.
    /// - Returns: The opening sequence of that status's color.
    private static func style(for status: HealthStatus) -> String {
        switch status {
        case .ok: TerminalStyle.passing
        case .warning: TerminalStyle.attention
        case .error: TerminalStyle.broken
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
    /// The report itself is not encoded — only ``checks`` is — because the array
    /// is what a script reads, and ``worstStatus`` and ``exitCode`` are each
    /// derived from it.
    ///
    /// - Parameter prettyPrinted: Whether to spread the array over several lines
    ///   for a person to read. The default is `false`, which is the compact form
    ///   a script wants.
    /// - Returns: The UTF-8 JSON bytes of ``checks``.
    /// - Throws: Whatever `JSONEncoder.encode` throws.
    public func jsonData(prettyPrinted: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        return try encoder.encode(checks)
    }
}
