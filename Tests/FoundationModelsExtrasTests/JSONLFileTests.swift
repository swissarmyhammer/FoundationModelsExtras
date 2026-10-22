import FixtureSupport
import Foundation
import Synchronization
import TelemetryTestSupport
import Testing

@testable import FoundationModelsExtras

/// Proves the rules of `JSONLFile`: the file only grows, each append is one
/// whole line in one `write(2)` with an `fsync` before the append returns, a
/// torn final line is dropped with a warning, an append after a torn tail
/// starts a new line, a whole line that does not decode is skipped with a
/// warning, the newest line for a key wins and a tombstone line removes the
/// key.
@Suite("JSONL file")
struct JSONLFileTests {
  /// The name of the log file in the folder of each test.
  private static let fileName = "records.jsonl"

  /// The byte that ends each line of a JSONL file.
  private static let newline = UInt8(ascii: "\n")

  /// The value of the oldest record of a key.
  private static let oldValue = 1

  /// The value of a record of a different key.
  private static let otherValue = 2

  /// The value of the newest record of a key.
  private static let newValue = 3

  /// The number of the corrupt line in the corrupt files of the tests: the
  /// line after the first one.
  private static let corruptLineNumber = 2

  /// The number of records that each of the two concurrent appenders writes.
  private static let recordsPerAppender = 200

  /// The size of the padding of each record of the concurrent appenders. It
  /// is more than `PIPE_BUF`, so the line is more than the size that POSIX
  /// promises to write whole to a pipe.
  private static let concurrentPaddingBytes = 16 * 1024

  /// The bytes of a torn final line: the start of a record, with no newline.
  private static let tornTail = Data(#"{"id":"c","val"#.utf8)

  /// A whole first line of a file that a test writes with no `JSONLFile`: an
  /// ``Entry`` with each of its keys.
  private static let validFirstLine = #"{"id":"a","padding":"","removed":false,"value":1}"# + "\n"

  /// The record of ``validFirstLine``.
  private static let validFirstEntry = Entry(id: "a", value: oldValue)

  /// A whole line that holds no JSON.
  private static let corruptLine = "not json\n"

  /// The warning of a read that skips ``corruptLine`` after
  /// ``validFirstLine``: the line number and the byte offset, never the path
  /// or the bytes of the line.
  private static let corruptLineWarning = TelemetryCapture.LogRecord(
    level: .warning,
    message: "\(ExtrasTelemetry.JSONLLogMessage.corruptLineSkipped)",
    metadata: [
      ExtrasTelemetry.LogMetadataKey.lineNumber: .string("\(corruptLineNumber)"),
      ExtrasTelemetry.LogMetadataKey.byteOffset: .string("\(validFirstLine.utf8.count)"),
    ],
    label: ExtrasTelemetry.logLabel
  )

  /// One record of the tests: a value for a key, or a tombstone for the key.
  private struct Entry: Codable, Equatable, JSONLKeyedRecord {
    /// The key of the record.
    let id: String

    /// The value of the record.
    let value: Int

    /// `true` for a tombstone, which removes the key.
    var removed = false

    /// Filler bytes that make the line long.
    var padding = ""

    var key: String { id }

    var isTombstone: Bool { removed }
  }

  /// Makes a new empty folder and the log file in it. The file is not on
  /// disk yet.
  ///
  /// - Returns: The folder, which the test removes, and the log file.
  /// - Throws: The error of `TemporaryDirectory.make()`.
  private static func makeFile() throws -> (folder: URL, file: JSONLFile) {
    let folder = try TemporaryDirectory.make()
    return (folder, JSONLFile(url: folder.appendingPathComponent(fileName)))
  }

  /// Appends `bytes` to the file at `url` with no `JSONLFile`, the way a
  /// crash or damage leaves bytes on disk.
  ///
  /// - Parameters:
  ///   - bytes: The bytes to add at the end of the file.
  ///   - url: The file, which must exist.
  /// - Throws: The error of the file handle.
  private static func appendRaw(_ bytes: Data, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: bytes)
  }

  /// Writes `text` as the whole file at `url`, with no `JSONLFile`.
  ///
  /// - Parameters:
  ///   - text: The content of the file.
  ///   - url: The file to write.
  /// - Throws: The error of the write.
  private static func writeRaw(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url)
  }

  /// The identity of the file at `url` on its volume, which a replace of the
  /// file changes.
  ///
  /// - Parameter url: The file.
  /// - Returns: The file number of the file.
  /// - Throws: The error of the file manager, or of `#require` when the
  ///   attributes hold no file number.
  private static func fileNumber(of url: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.systemFileNumber] as? UInt64)
  }

  @Test func eachAppendOnlyAddsBytesAtTheEndOfTheSameFile() throws {
    let (folder, file) = try Self.makeFile()
    defer { try? FileManager.default.removeItem(at: folder) }

    try file.append(Entry(id: "a", value: Self.oldValue))
    let first = try Data(contentsOf: file.url)
    let firstNumber = try Self.fileNumber(of: file.url)
    try file.append(Entry(id: "b", value: Self.otherValue))
    let second = try Data(contentsOf: file.url)

    #expect(second.count > first.count)
    #expect(second.prefix(first.count) == first)
    #expect(try Self.fileNumber(of: file.url) == firstNumber)
  }

  @Test func eachAppendAddsOneWholeLineThatReadsBack() throws {
    let (folder, file) = try Self.makeFile()
    defer { try? FileManager.default.removeItem(at: folder) }
    let entries = [
      Entry(id: "a", value: Self.oldValue), Entry(id: "b", value: Self.otherValue),
      Entry(id: "a", value: Self.newValue),
    ]

    for entry in entries {
      try file.append(entry)
    }

    let data = try Data(contentsOf: file.url)
    #expect(data.last == Self.newline)
    #expect(data.filter { $0 == Self.newline }.count == entries.count)
    #expect(try file.records(as: Entry.self) == entries)
  }

  @Test func eachAppendIsOneWriteOfTheWholeLineAndThenOneSync() throws {
    let (folder, _) = try Self.makeFile()
    defer { try? FileManager.default.removeItem(at: folder) }
    let calls = RecordedCalls()
    let file = JSONLFile(url: folder.appendingPathComponent(Self.fileName), calls: calls.recording)

    try file.append(Entry(id: "a", value: Self.oldValue))
    try file.append(Entry(id: "b", value: Self.otherValue))

    let lines = try Data(contentsOf: file.url).split(separator: Self.newline).map {
      Data($0) + [Self.newline]
    }
    #expect(calls.events == lines.flatMap { [RecordedCalls.Event.write($0), .sync] })
  }

  @Test func aShortWriteThrows() throws {
    let (folder, _) = try Self.makeFile()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = JSONLFile(
      url: folder.appendingPathComponent(Self.fileName), calls: RecordedCalls.halfWrite)
    let line = try JSONLFile.line(of: Entry(id: "a", value: Self.oldValue))

    #expect(
      throws: JSONLFileError.shortWrite(
        written: line.count / RecordedCalls.shortWriteDivisor, expected: line.count)
    ) {
      try file.append(Entry(id: "a", value: Self.oldValue))
    }
  }

  @Test func anAppendToAMissingFolderThrows() throws {
    let (folder, _) = try Self.makeFile()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = JSONLFile(
      url: folder.appendingPathComponent("missing").appendingPathComponent(Self.fileName))

    #expect(throws: JSONLFileError.openFailed(errno: ENOENT)) {
      try file.append(Entry(id: "a", value: Self.oldValue))
    }
  }

  @Test func aMissingFileHoldsNoRecords() throws {
    let (folder, file) = try Self.makeFile()
    defer { try? FileManager.default.removeItem(at: folder) }

    #expect(try file.records(as: Entry.self).isEmpty)
  }

  @Test func aTornFinalLineIsDroppedWithAWarningThatNamesItsOffset() async throws {
    let (folder, file) = try Self.makeFile()
    defer { try? FileManager.default.removeItem(at: folder) }
    let entries = [Entry(id: "a", value: Self.oldValue), Entry(id: "b", value: Self.otherValue)]
    for entry in entries {
      try file.append(entry)
    }
    let tornOffset = try Data(contentsOf: file.url).count
    try Self.appendRaw(Self.tornTail, to: file.url)

    let (records, context) = try await TelemetryCapture.run(forbidding: [folder.path]) { context in
      (try file.records(as: Entry.self), context)
    }

    #expect(records == entries)
    let expected = TelemetryCapture.LogRecord(
      level: .warning,
      message: "\(ExtrasTelemetry.JSONLLogMessage.tornTailDropped)",
      metadata: [ExtrasTelemetry.LogMetadataKey.byteOffset: .string("\(tornOffset)")],
      label: ExtrasTelemetry.logLabel
    )
    #expect(context.logRecords == [expected])
  }

  @Test func aCorruptMiddleLineIsSkippedWithAWarningAndTheLinesAroundItAreKept() async throws {
    let (folder, file) = try Self.makeFile()
    defer { try? FileManager.default.removeItem(at: folder) }
    try Self.writeRaw(Self.validFirstLine + Self.corruptLine + Self.validFirstLine, to: file.url)

    let (records, context) = try await TelemetryCapture.run(forbidding: [folder.path]) { context in
      (try file.records(as: Entry.self), context)
    }

    #expect(records == [Self.validFirstEntry, Self.validFirstEntry])
    #expect(context.logRecords == [Self.corruptLineWarning])
  }

  @Test func aCorruptFinalLineWithItsNewlineIsSkippedWithAWarning() async throws {
    let (folder, file) = try Self.makeFile()
    defer { try? FileManager.default.removeItem(at: folder) }
    try Self.writeRaw(Self.validFirstLine + Self.corruptLine, to: file.url)

    let (records, context) = try await TelemetryCapture.run(forbidding: [folder.path]) { context in
      (try file.records(as: Entry.self), context)
    }

    #expect(records == [Self.validFirstEntry])
    #expect(context.logRecords == [Self.corruptLineWarning])
  }

  @Test func anAppendAfterATornTailStartsItsLineOnANewLine() throws {
    let (folder, file) = try Self.makeFile()
    defer { try? FileManager.default.removeItem(at: folder) }
    try file.append(Entry(id: "a", value: Self.oldValue))
    try Self.appendRaw(Self.tornTail, to: file.url)
    let before = try Data(contentsOf: file.url)
    let entry = Entry(id: "b", value: Self.otherValue)

    try file.append(entry)

    #expect(try Data(contentsOf: file.url) == before + [Self.newline] + JSONLFile.line(of: entry))
  }

  @Test func aCrashThenAnAppendThenAReadGivesEveryWholeRecord() throws {
    let (folder, file) = try Self.makeFile()
    defer { try? FileManager.default.removeItem(at: folder) }
    let before = [Entry(id: "a", value: Self.oldValue), Entry(id: "b", value: Self.otherValue)]
    for entry in before {
      try file.append(entry)
    }
    try Self.appendRaw(Self.tornTail, to: file.url)
    let after = Entry(id: "a", value: Self.newValue)

    try file.append(after)

    #expect(try file.records(as: Entry.self) == before + [after])
  }

  @Test func theNewestLineForAKeyWins() {
    let folded = JSONLFile.fold([
      Entry(id: "a", value: Self.oldValue), Entry(id: "b", value: Self.otherValue),
      Entry(id: "a", value: Self.newValue),
    ])

    #expect(
      folded == [
        "a": Entry(id: "a", value: Self.newValue), "b": Entry(id: "b", value: Self.otherValue),
      ])
  }

  @Test func aTombstoneRemovesTheKey() {
    let folded = JSONLFile.fold([
      Entry(id: "a", value: Self.oldValue), Entry(id: "b", value: Self.otherValue),
      Entry(id: "b", value: Self.otherValue, removed: true),
    ])

    #expect(folded == ["a": Entry(id: "a", value: Self.oldValue)])
  }

  @Test func aLineAfterATombstoneBringsTheKeyBack() {
    let folded = JSONLFile.fold([
      Entry(id: "a", value: Self.oldValue), Entry(id: "a", value: Self.oldValue, removed: true),
      Entry(id: "a", value: Self.newValue),
    ])

    #expect(folded == ["a": Entry(id: "a", value: Self.newValue)])
  }

  @Test func theLatestRecordsOfAFileFoldItsLinesAndTheRemoveIsAnAppendedLine() throws {
    let (folder, file) = try Self.makeFile()
    defer { try? FileManager.default.removeItem(at: folder) }
    try file.append(Entry(id: "a", value: Self.oldValue))
    try file.append(Entry(id: "b", value: Self.otherValue))
    let before = try Data(contentsOf: file.url)

    try file.append(Entry(id: "a", value: Self.oldValue, removed: true))

    #expect(try file.latestRecords(as: Entry.self) == ["b": Entry(id: "b", value: Self.otherValue)])
    #expect(try Data(contentsOf: file.url).prefix(before.count) == before)
  }

  @Test func twoConcurrentAppendersWriteOnlyWholeLines() async throws {
    let (folder, _) = try Self.makeFile()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent(Self.fileName)
    let padding = String(repeating: "x", count: Self.concurrentPaddingBytes)
    let appenders = ["first", "second"]

    // Each appender is its own `JSONLFile`, and each append opens its own
    // open file description, as an append of a second process does.
    try await withThrowingTaskGroup { group in
      for appender in appenders {
        group.addTask {
          let file = JSONLFile(url: url)
          for index in 0..<Self.recordsPerAppender {
            try file.append(Entry(id: appender, value: index, padding: padding))
          }
        }
      }
      try await group.waitForAll()
    }

    let records = try JSONLFile(url: url).records(as: Entry.self)
    #expect(records.count == appenders.count * Self.recordsPerAppender)
    #expect(records.allSatisfy { $0.padding == padding })
    for appender in appenders {
      #expect(
        records.filter { $0.id == appender }.map(\.value) == Array(0..<Self.recordsPerAppender))
    }
  }
}

/// The write and the sync calls of the appends of one test, in order.
///
/// A `final class` around a `Mutex`, not an `actor`: the calls of
/// `JSONLFile.Calls` are synchronous and cannot `await`.
private final class RecordedCalls: Sendable {
  /// One call of an append.
  enum Event: Equatable {
    /// A `write(2)` of these bytes.
    case write(Data)

    /// An `fsync(2)`.
    case sync
  }

  /// The part of the bytes of a write that ``halfWrite`` puts on disk: one
  /// in this number.
  static let shortWriteDivisor = 2

  /// The calls so far.
  private let recorded = Mutex<[Event]>([])

  /// The calls so far, in order.
  var events: [Event] {
    recorded.withLock { $0 }
  }

  /// The calls of the system, which also record each call here.
  var recording: JSONLFile.Calls {
    JSONLFile.Calls(
      write: { descriptor, bytes in
        self.recorded.withLock { $0.append(.write(Data(bytes))) }
        return JSONLFile.Calls.system.write(descriptor, bytes)
      },
      sync: { descriptor in
        self.recorded.withLock { $0.append(.sync) }
        return JSONLFile.Calls.system.sync(descriptor)
      })
  }

  /// The calls of the system, but each write puts only the first half of its
  /// bytes on disk, as a full disk does.
  static let halfWrite = JSONLFile.Calls(
    write: { descriptor, bytes in
      JSONLFile.Calls.system.write(
        descriptor, UnsafeRawBufferPointer(rebasing: bytes.prefix(bytes.count / shortWriteDivisor)))
    },
    sync: JSONLFile.Calls.system.sync)
}
