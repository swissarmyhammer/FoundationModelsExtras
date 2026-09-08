import Foundation
import FoundationModelsExtras
import Testing

/// Behavioral tests for the plain doctor renderer of `doctor-plan.md` §6: the
/// plain table a person reads, the rule that no rendering ever holds an escape
/// sequence, and the JSON array a script reads.
///
/// The suite imports the module plainly rather than with `@testable`, so it
/// exercises the same surface a consumer package sees — the tests fail to
/// compile if any of this API stops being `public`.
@Suite("Plain doctor renderer") struct PlainRendererTests {

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

    /// The ANSI escape character, which opens every color sequence a terminal
    /// reads. No rendering may hold one, and no source file of the module may
    /// spell one.
    private static let ansiEscape = "\u{001B}"

    /// What the renderer writes in place of a fix for a finding that carries
    /// none, which `doctor-plan.md` §6 requires stay visible.
    private static let missingFixText = "the component gave no fix"

    /// How far past a row the fix line stands, which is one line.
    private static let fixLineOffset = 1

    /// The one message the alignment test gives to two findings of different
    /// name lengths, so the offset of this text is the only thing that moves.
    private static let sharedMessage = "the check ran"

    // MARK: - The source files of the module

    /// Where the doctor module stands, relative to the package root.
    private static let doctorModulePath = "Sources/FoundationModelsExtras/Doctor"

    /// The one import a doctor source file may state. Foundation gives the
    /// renderer `Data`, `FileHandle` and the JSON coder, and nothing about a
    /// terminal or a color.
    private static let permittedImport = "import Foundation"

    /// The spellings of the escape character a Swift source file could carry,
    /// read in lower case: the two Unicode escape forms, and the hex byte.
    private static let escapeSpellings = ["u{001b}", "u{1b}", "x1b"]

    /// The source files of the doctor module, read whole.
    ///
    /// - Returns: The text of each `.swift` file, keyed by the file name.
    /// - Throws: Whatever listing the directory or reading a file throws.
    private static func doctorModuleSources() throws -> [String: String] {
        let directory = PackageRootValidation.packageRoot().appending(path: doctorModulePath)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".swift") }
        let entries = try names.map { name in
            (name, try String(contentsOf: directory.appending(path: name), encoding: .utf8))
        }
        return Dictionary(uniqueKeysWithValues: entries)
    }

    /// The `import` lines of one source file, with their indentation removed.
    ///
    /// - Parameter source: The text of the file.
    /// - Returns: Each line that opens with `import`.
    private static func importLines(of source: String) -> [String] {
        source.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("import ") }
    }

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

    // MARK: - The rule of doctor-plan.md §6: no escape sequence, ever

    @Test func `the output of every status holds no ansi escape`() {
        let text = PlainTextDoctorRenderer().render(Self.threeStatusReport())

        // `allSatisfy` is `rethrows`, and the `#expect` macro takes a call it
        // decomposes apart as one that can throw, so the reading is made here
        // and the macro reads the answer.
        let everyScalarIsAscii = text.unicodeScalars.allSatisfy(\.isASCII)

        #expect(!text.contains(Self.ansiEscape))
        #expect(everyScalarIsAscii)
    }

    /// The renderer cannot write an escape sequence it never spells. This holds
    /// the module's source to that, so a color option cannot come back under
    /// any name.
    @Test func `no doctor source file spells the escape character`() throws {
        let sources = try Self.doctorModuleSources()

        #expect(!sources.isEmpty)
        for (name, text) in sources {
            let lowered = text.lowercased()
            #expect(!lowered.contains(Self.ansiEscape), "\(name) holds the escape character")
            for spelling in Self.escapeSpellings {
                #expect(!lowered.contains(spelling), "\(name) spells \(spelling)")
            }
        }
    }

    /// This package is a library that also runs inside a Mac app, so no file of
    /// the module imports a terminal or a color library (doctor-plan.md §6).
    @Test func `no doctor source file imports a terminal or color library`() throws {
        let sources = try Self.doctorModuleSources()

        #expect(!sources.isEmpty)
        for (name, text) in sources {
            let imports = Self.importLines(of: text)
            #expect(imports.allSatisfy { $0 == Self.permittedImport }, "\(name) imports \(imports)")
        }
    }

    // MARK: - The fix line under a row that reports a problem

    @Test func `a warning row is followed by its fix line`() throws {
        let lines = Self.plainLines(of: Self.threeStatusReport())

        let row = try #require(lines.firstIndex { $0.contains(Self.attentionName) })

        #expect(lines[row + Self.fixLineOffset].contains(Self.attentionFix))
    }

    @Test func `an error row is followed by its fix line`() throws {
        let lines = Self.plainLines(of: Self.threeStatusReport())

        let row = try #require(lines.firstIndex { $0.contains(Self.brokenName) })

        #expect(lines[row + Self.fixLineOffset].contains(Self.brokenFix))
    }

    @Test func `an ok row is followed by no fix line`() throws {
        let lines = Self.plainLines(of: Self.threeStatusReport())

        let row = try #require(lines.firstIndex { $0.contains(Self.passingName) })

        #expect(lines[row + Self.fixLineOffset].contains(Self.attentionName))
    }

    @Test func `an error carrying no fix is followed by the line that says so`() throws {
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
    @Test func `the message column starts at the same offset whatever the name length`() throws {
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

    @Test func `the rows keep the order of the report checks`() throws {
        let lines = Self.plainLines(of: Self.threeStatusReport())

        let passing = try #require(lines.firstIndex { $0.contains(Self.passingName) })
        let attention = try #require(lines.firstIndex { $0.contains(Self.attentionName) })
        let broken = try #require(lines.firstIndex { $0.contains(Self.brokenName) })

        #expect(passing < attention)
        #expect(attention < broken)
    }

    // MARK: - The JSON a script reads

    @Test func `json data decodes back to the checks of the report`() throws {
        let report = Self.threeStatusReport()

        let decoded = try JSONDecoder().decode([HealthCheck].self, from: report.jsonData())

        #expect(decoded == report.checks)
    }

    @Test func `json data of one check writes its keys in sorted order`() throws {
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

    @Test func `pretty printed json data decodes back to the checks of the report`() throws {
        let report = Self.threeStatusReport()

        let data = try report.jsonData(prettyPrinted: true)

        #expect(String(decoding: data, as: UTF8.self).contains("\n"))
        #expect(try JSONDecoder().decode([HealthCheck].self, from: data) == report.checks)
    }

    // MARK: - Writing to a destination

    /// `write(_:to:)` writes the same plain text `render(_:)` returns, and it
    /// reads nothing about the destination.
    ///
    /// The write handle is closed BEFORE the read. A read to end with the write
    /// handle still open never returns, and the test would hang in place of
    /// failing.
    @Test func `writing to a handle writes the rendering unchanged`() throws {
        let pipe = Pipe()
        let report = Self.threeStatusReport()

        try PlainTextDoctorRenderer().write(report, to: pipe.fileHandleForWriting)
        try pipe.fileHandleForWriting.close()

        let text = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        #expect(text == PlainTextDoctorRenderer().render(report))
        #expect(!text.contains(Self.ansiEscape))
    }
}
