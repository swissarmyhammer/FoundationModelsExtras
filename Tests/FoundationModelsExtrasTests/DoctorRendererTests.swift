import Foundation
import FoundationModelsExtras
import Testing

/// Behavioral tests for the doctor renderer of `doctor-plan.md` §6: the plain
/// table a person reads, the color the renderer writes only when the
/// destination is a terminal, and the JSON array a script reads.
///
/// The suite imports the module plainly rather than with `@testable`, so it
/// exercises the same surface a consumer package sees — the tests fail to
/// compile if any of this API stops being `public`.
@Suite("Doctor renderer") struct DoctorRendererTests {

    // MARK: - The words the stand-in findings carry

    /// What the passing finding checked.
    private static let passingName = "configuration"

    /// What the finding that needs attention checked.
    private static let attentionName = "transcripts"

    /// What the broken finding checked.
    private static let brokenName = "model"

    /// What the passing finding found.
    ///
    /// No message of this file repeats a name of it, so a search for a name
    /// finds the row of that name and never the message of another row.
    private static let passingMessage = "the settings loaded"

    /// What the finding that needs attention found.
    private static let attentionMessage = "the directory is not writable"

    /// What the broken finding found.
    private static let brokenMessage = "the model is absent"

    /// The action the finding that needs attention carries.
    private static let attentionFix = "run chmod u plus w on the directory"

    /// The action the broken finding carries.
    private static let brokenFix = "download the model"

    /// The group every stand-in finding belongs to.
    private static let findingCategory = "probe"

    // MARK: - The bytes and the words the assertions read

    /// The ANSI escape character, `0x1B`, which opens every color sequence a
    /// terminal reads.
    ///
    /// The plain output must hold none of these, and the colored output must
    /// hold one or more. Both halves are pinned, because a renderer that
    /// ignored `useColor` altogether would pass the first half alone.
    private static let ansiEscape = "\u{001B}"

    /// What the renderer writes in place of a fix for a finding that carries
    /// none, which `doctor-plan.md` §6 requires stay visible.
    private static let missingFixText = "the component gave no fix"

    /// How far past a row the fix line stands, which is one line.
    private static let fixLineOffset = 1

    /// The one message the alignment test gives to two findings of different
    /// name lengths, so the offset of this text is the only thing that moves.
    private static let sharedMessage = "the check ran"

    // MARK: - Building a report

    /// A report holding one finding of each status, in the order stated here.
    ///
    /// - Returns: A report of three findings: passing, needing attention, and
    ///   broken.
    private static func threeStatusReport() -> DoctorReport {
        DoctorReport(checks: [
            .ok(name: passingName, message: passingMessage, category: findingCategory),
            .warning(
                name: attentionName, message: attentionMessage, fix: attentionFix,
                category: findingCategory),
            .error(
                name: brokenName, message: brokenMessage, fix: brokenFix,
                category: findingCategory),
        ])
    }

    /// The lines of a rendering.
    ///
    /// - Parameter rendering: The text the renderer wrote.
    /// - Returns: One entry for each line, with the empty entry the closing
    ///   newline leaves dropped.
    private static func lines(of rendering: String) -> [String] {
        rendering.split(separator: "\n").map(String.init)
    }

    /// The lines of the plain rendering of a report.
    ///
    /// - Parameter report: The report to render.
    /// - Returns: One entry for each line the renderer wrote.
    private static func plainLines(of report: DoctorReport) -> [String] {
        lines(of: PlainTextDoctorRenderer().render(report))
    }

    // MARK: - The color rule of doctor-plan.md §6

    @Test func thePlainOutputOfEveryStatusHoldsNoAnsiEscape() {
        let text = PlainTextDoctorRenderer(useColor: false).render(Self.threeStatusReport())

        // `allSatisfy` is `rethrows`, and the `#expect` macro takes a call it
        // decomposes apart as one that can throw, so the reading is made here
        // and the macro reads the answer.
        let everyScalarIsAscii = text.unicodeScalars.allSatisfy(\.isASCII)

        #expect(!text.contains(Self.ansiEscape))
        #expect(everyScalarIsAscii)
    }

    /// The other half of the §6 rule, named row by row: a renderer that ignored
    /// `useColor` altogether would pass the plain test above on its own.
    @Test func theColoredWarningAndErrorRowsEachHoldAnAnsiEscape() throws {
        let text = PlainTextDoctorRenderer(useColor: true).render(Self.threeStatusReport())
        let rows = Self.lines(of: text)

        let attentionRow = try #require(rows.first { $0.contains(Self.attentionName) })
        let brokenRow = try #require(rows.first { $0.contains(Self.brokenName) })

        #expect(attentionRow.contains(Self.ansiEscape))
        #expect(brokenRow.contains(Self.ansiEscape))
    }

    // MARK: - The fix line under a row that reports a problem

    @Test func aWarningRowIsFollowedByItsFixLine() throws {
        let lines = Self.plainLines(of: Self.threeStatusReport())

        let row = try #require(lines.firstIndex { $0.contains(Self.attentionName) })

        #expect(lines[row + Self.fixLineOffset].contains(Self.attentionFix))
    }

    @Test func anErrorRowIsFollowedByItsFixLine() throws {
        let lines = Self.plainLines(of: Self.threeStatusReport())

        let row = try #require(lines.firstIndex { $0.contains(Self.brokenName) })

        #expect(lines[row + Self.fixLineOffset].contains(Self.brokenFix))
    }

    @Test func anOkRowIsFollowedByNoFixLine() throws {
        let lines = Self.plainLines(of: Self.threeStatusReport())

        let row = try #require(lines.firstIndex { $0.contains(Self.passingName) })

        #expect(lines[row + Self.fixLineOffset].contains(Self.attentionName))
    }

    @Test func anErrorCarryingNoFixIsFollowedByTheLineThatSaysSo() throws {
        let report = DoctorReport(checks: [
            HealthCheck(
                name: Self.brokenName, status: .error, message: Self.brokenMessage, fix: nil,
                category: Self.findingCategory)
        ])
        let lines = Self.plainLines(of: report)

        let row = try #require(lines.firstIndex { $0.contains(Self.brokenName) })

        #expect(lines[row + Self.fixLineOffset].contains(Self.missingFixText))
    }

    // MARK: - The columns line up

    /// How far into a row its message stands.
    ///
    /// - Parameter row: The row to read.
    /// - Returns: How many characters stand before ``sharedMessage``, or `nil`
    ///   when the row carries no such message.
    private static func messageOffset(in row: String) -> Int? {
        guard let start = row.range(of: sharedMessage)?.lowerBound else { return nil }
        return row.distance(from: row.startIndex, to: start)
    }

    /// Two findings that carry the same message under names of different
    /// lengths: the padding is what has to put the two messages at one offset.
    @Test func theMessageColumnStartsAtTheSameOffsetWhateverTheNameLength() throws {
        let report = DoctorReport(checks: [
            .ok(name: Self.brokenName, message: Self.sharedMessage, category: Self.findingCategory),
            .ok(
                name: Self.attentionName, message: Self.sharedMessage,
                category: Self.findingCategory),
        ])
        let lines = Self.plainLines(of: report)

        let shortNameRow = try #require(lines.first { $0.contains(Self.brokenName) })
        let longNameRow = try #require(lines.first { $0.contains(Self.attentionName) })

        let shortNameOffset = try #require(Self.messageOffset(in: shortNameRow))
        let longNameOffset = try #require(Self.messageOffset(in: longNameRow))

        #expect(shortNameOffset == longNameOffset)
    }

    // MARK: - The order of the rows

    @Test func theRowsKeepTheOrderOfTheReportChecks() throws {
        let lines = Self.plainLines(of: Self.threeStatusReport())

        let passing = try #require(lines.firstIndex { $0.contains(Self.passingName) })
        let attention = try #require(lines.firstIndex { $0.contains(Self.attentionName) })
        let broken = try #require(lines.firstIndex { $0.contains(Self.brokenName) })

        #expect(passing < attention)
        #expect(attention < broken)
    }

    // MARK: - The JSON a script reads

    @Test func jsonDataDecodesBackToTheChecksOfTheReport() throws {
        let report = Self.threeStatusReport()

        let decoded = try JSONDecoder().decode([HealthCheck].self, from: report.jsonData())

        #expect(decoded == report.checks)
    }

    @Test func jsonDataOfOneCheckWritesItsKeysInSortedOrder() throws {
        let report = DoctorReport(checks: [
            .ok(
                name: Self.passingName, message: Self.passingMessage,
                category: Self.findingCategory)
        ])

        let text = String(decoding: try report.jsonData(), as: UTF8.self)

        #expect(
            text
                == #"[{"category":"\#(Self.findingCategory)","message":"\#(Self.passingMessage)","name":"\#(Self.passingName)","status":"ok"}]"#
        )
    }

    @Test func prettyPrintedJsonDataDecodesBackToTheChecksOfTheReport() throws {
        let report = Self.threeStatusReport()

        let data = try report.jsonData(prettyPrinted: true)

        #expect(String(decoding: data, as: UTF8.self).contains("\n"))
        #expect(try JSONDecoder().decode([HealthCheck].self, from: data) == report.checks)
    }

    // MARK: - Writing to a destination that is not a terminal

    /// A pipe is not a terminal, so `write(_:to:)` must write plain text even
    /// though this renderer was built with `useColor: true`.
    ///
    /// The write handle is closed BEFORE the read. A read to end with the write
    /// handle still open never returns, and the test would hang in place of
    /// failing.
    @Test func writingToAPipeHoldsNoAnsiEscape() throws {
        let pipe = Pipe()

        try PlainTextDoctorRenderer(useColor: true)
            .write(Self.threeStatusReport(), to: pipe.fileHandleForWriting)
        try pipe.fileHandleForWriting.close()

        let text = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        #expect(!text.contains(Self.ansiEscape))
        #expect(text.contains(Self.brokenName))
    }
}
