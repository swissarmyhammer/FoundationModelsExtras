import Darwin
import Foundation

/// One JSON Lines file: one JSON record on each line. It is the only way that
/// a package of the family writes or reads a `.jsonl` file.
///
/// The rules of the file:
///
/// - **Append only.** An append opens the file with `O_APPEND | O_CREAT`. No
///   code truncates, rewrites or replaces the file, and no code seeks in it.
///   The file only grows, and the bytes already in it never change.
/// - **One full line for each write.** An append encodes the record, adds the
///   `\n`, and gives the whole line to one `write(2)`. This code buffers
///   nothing. A short write throws, and no second write sends the rest,
///   because the rest could land after the line of another appender.
/// - **Heal a torn tail.** Before its write, an append reads the last byte of
///   the file with `pread(2)`, which moves no file offset. When the file is
///   not empty and that byte is not `\n`, a crash tore the last line, and the
///   append writes a `\n` in front of its line, in the same `write(2)`. The
///   torn bytes become a whole line of their own that does not decode, and
///   the new record starts on a line of its own. When two appenders heal the
///   same torn tail at the same time, the second `\n` makes an empty line,
///   which a read skips like any other line that does not decode.
/// - **Flush.** An append calls `fsync(2)` after its line, before it returns.
/// - **Concurrent appenders stay whole.** Each append opens its own open file
///   description with `O_APPEND`, so the kernel puts each line at the end of
///   the file in one piece, also when two processes append to one file, for
///   example the Router and the ACP agent on `sessions.jsonl`.
/// - **Read.** A read decodes the file line by line. The bytes after the last
///   `\n` are a torn final line: the expected artifact of a crash in an
///   append. The read drops them and logs a warning with their byte offset. A
///   whole line, one that ends with its `\n`, that does not decode is skipped:
///   the read logs a warning with its line number and its byte offset, and
///   keeps the records of the lines around it. Such a line is most often a
///   torn line that a later append healed. No warning holds the path or the
///   bytes of a line.
/// - **Last line wins.** ``fold(_:)`` keeps the newest record for each key of
///   a ``JSONLKeyedRecord``, and a tombstone record removes the key. A remove
///   is always an appended tombstone line, never a rewrite of the file.
///
/// Each line is the JSON of the record with sorted keys, slashes not escaped,
/// and ISO 8601 dates.
public struct JSONLFile: Sendable {
  /// The system calls of an append that a test can watch: the `write(2)` of
  /// the line and the `fsync(2)` after it.
  struct Calls: Sendable {
    /// Writes the bytes to the descriptor, as `write(2)` does.
    let write: @Sendable (_ descriptor: Int32, _ bytes: UnsafeRawBufferPointer) -> Int

    /// Flushes the descriptor to the disk, as `fsync(2)` does.
    let sync: @Sendable (_ descriptor: Int32) -> Int32

    /// The calls of the system.
    static let system = Calls(
      write: { descriptor, bytes in Darwin.write(descriptor, bytes.baseAddress, bytes.count) },
      sync: { descriptor in Darwin.fsync(descriptor) })
  }

  /// The flags of the open of an append: each write at the end, and create
  /// the file when it is not there. Read and write, so that the heal check
  /// can `pread(2)` the last byte through the same descriptor; `pread(2)`
  /// moves no offset, and `O_APPEND` puts each write at the end.
  private static let appendFlags = O_RDWR | O_APPEND | O_CREAT | O_CLOEXEC

  /// The permissions of a new file: the owner reads and writes, the others
  /// read.
  private static let newFileMode: mode_t = 0o644

  /// The byte that ends each line.
  private static let newline = UInt8(ascii: "\n")

  /// The value that a system call gives when it fails.
  private static let systemCallFailure = -1

  /// The file. It does not have to exist: the first append creates it. Its
  /// folder must exist.
  public let url: URL

  /// The system calls of an append.
  private let calls: Calls

  /// Makes the value of the JSONL file at `url`. It opens nothing.
  ///
  /// - Parameter url: The file. The first append creates it, in a folder
  ///   that must exist.
  public init(url: URL) {
    self.init(url: url, calls: .system)
  }

  /// Makes the value of the JSONL file at `url`, with the system calls that
  /// `calls` gives.
  ///
  /// - Parameters:
  ///   - url: The file.
  ///   - calls: The write and the sync of each append.
  init(url: URL, calls: Calls) {
    self.url = url
    self.calls = calls
  }

  /// Appends `record` as one line at the end of the file, and flushes the
  /// file to the disk before it returns. When the file ends with a torn
  /// line, the write starts with a `\n` that ends it.
  ///
  /// - Parameter record: The record to append.
  /// - Throws: ``JSONLFileError/encodingFailed(description:)`` when the
  ///   record does not encode, ``JSONLFileError/openFailed(errno:)``,
  ///   ``JSONLFileError/tailCheckFailed(errno:)``,
  ///   ``JSONLFileError/writeFailed(errno:)``,
  ///   ``JSONLFileError/shortWrite(written:expected:)``,
  ///   ``JSONLFileError/syncFailed(errno:)`` or
  ///   ``JSONLFileError/closeFailed(errno:)`` when a system call fails.
  public func append(_ record: some Encodable) throws(JSONLFileError) {
    let line = try Self.line(of: record)
    let descriptor = try openForAppending()
    do throws(JSONLFileError) {
      let bytes = try endsWithTornLine(descriptor) ? Data([Self.newline]) + line : line
      try write(bytes, to: descriptor)
      try synchronize(descriptor)
    } catch {
      // The failure of the write or of the sync is the error of the append.
      _ = Darwin.close(descriptor)
      throw error
    }
    try close(descriptor)
  }

  /// Reads the records of the file, in the order of their lines.
  ///
  /// A torn final line, the bytes after the last `\n`, is dropped with a
  /// warning that holds its byte offset. A whole line that does not decode is
  /// skipped with a warning that holds its line number and its byte offset.
  ///
  /// - Parameter type: The type of each record.
  /// - Returns: The records of the lines that decode, oldest first. No
  ///   records when the file does not exist.
  /// - Throws: ``JSONLFileError/readFailed(description:)`` when the file
  ///   exists and does not read.
  public func records<Record: Decodable>(as type: Record.Type) throws(JSONLFileError) -> [Record] {
    guard let data = try contents() else {
      return []
    }
    let segments = data.split(separator: Self.newline, omittingEmptySubsequences: false)
    let decoder = Self.makeDecoder()
    let records = segments.dropLast().enumerated().compactMap { index, line in
      Self.decode(
        type, from: line, number: index + 1, byteOffset: line.startIndex - data.startIndex,
        with: decoder)
    }
    if let tail = segments.last, !tail.isEmpty {
      Self.logTornTail(at: tail.startIndex - data.startIndex)
    }
    return records
  }

  /// Reads the records of the file and folds them with ``fold(_:)``: the
  /// newest line for each key wins, and a tombstone removes the key.
  ///
  /// - Parameter type: The type of each record.
  /// - Returns: The newest record of each key that no tombstone removed.
  /// - Throws: The errors of ``records(as:)``.
  public func latestRecords<Record: JSONLKeyedRecord>(
    as type: Record.Type
  ) throws(JSONLFileError) -> [Record.Key: Record] {
    Self.fold(try records(as: type))
  }

  /// Folds records by key: the newest record of a key wins, and a tombstone
  /// removes the key. A record after a tombstone gives the key again.
  ///
  /// - Parameter records: The records, oldest first, as ``records(as:)``
  ///   gives them.
  /// - Returns: The newest record of each key that no tombstone removed.
  public static func fold<Record: JSONLKeyedRecord>(_ records: some Sequence<Record>) -> [Record
    .Key: Record]
  {
    records.reduce(into: [:]) { latest, record in
      latest[record.key] = record.isTombstone ? nil : record
    }
  }

  /// Gives the line of `record`: its JSON and the `\n`.
  ///
  /// - Parameter record: The record.
  /// - Returns: The bytes of one whole line.
  /// - Throws: ``JSONLFileError/encodingFailed(description:)`` when the
  ///   record does not encode.
  static func line(of record: some Encodable) throws(JSONLFileError) -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do {
      return try encoder.encode(record) + [newline]
    } catch {
      throw .encodingFailed(description: String(describing: error))
    }
  }

  /// Makes the decoder of the lines: ISO 8601 dates, as ``line(of:)``
  /// writes them.
  ///
  /// - Returns: A new decoder.
  private static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  /// Decodes one line that ends with its `\n`, or logs the warning of a
  /// skipped line when it does not decode.
  ///
  /// - Parameters:
  ///   - type: The type of the record.
  ///   - line: The bytes of the line, without the `\n`.
  ///   - number: The number of the line in the file. The first line is 1.
  ///   - byteOffset: The offset of the first byte of the line in the file.
  ///   - decoder: The decoder of the lines.
  /// - Returns: The record of the line, or `nil` when the line does not
  ///   decode.
  private static func decode<Record: Decodable>(
    _ type: Record.Type, from line: Data, number: Int, byteOffset: Int, with decoder: JSONDecoder
  ) -> Record? {
    do {
      return try decoder.decode(type, from: line)
    } catch {
      logSkippedLine(number: number, at: byteOffset)
      return nil
    }
  }

  /// Logs the warning of a skipped whole line that does not decode. The
  /// record holds the line number and the byte offset only, never the path
  /// or the bytes of the line.
  ///
  /// - Parameters:
  ///   - number: The number of the line in the file. The first line is 1.
  ///   - byteOffset: The offset of the first byte of the line in the file.
  private static func logSkippedLine(number: Int, at byteOffset: Int) {
    ExtrasTelemetry.makeLogger().warning(
      "\(ExtrasTelemetry.JSONLLogMessage.corruptLineSkipped)",
      metadata: [
        ExtrasTelemetry.LogMetadataKey.lineNumber: .string("\(number)"),
        ExtrasTelemetry.LogMetadataKey.byteOffset: .string("\(byteOffset)"),
      ])
  }

  /// Logs the warning of a dropped torn final line. The record holds the
  /// byte offset only, never the path or the bytes of the line.
  ///
  /// - Parameter byteOffset: The offset of the first byte of the torn line.
  private static func logTornTail(at byteOffset: Int) {
    ExtrasTelemetry.makeLogger().warning(
      "\(ExtrasTelemetry.JSONLLogMessage.tornTailDropped)",
      metadata: [ExtrasTelemetry.LogMetadataKey.byteOffset: .string("\(byteOffset)")])
  }

  /// Reads the whole file.
  ///
  /// - Returns: The bytes of the file, or `nil` when the file does not exist.
  /// - Throws: ``JSONLFileError/readFailed(description:)`` when the file
  ///   exists and does not read.
  private func contents() throws(JSONLFileError) -> Data? {
    do {
      return try Data(contentsOf: url)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return nil
    } catch {
      throw .readFailed(description: String(describing: error))
    }
  }

  /// Opens the file for one append.
  ///
  /// - Returns: The descriptor, which the caller closes.
  /// - Throws: ``JSONLFileError/openFailed(errno:)`` when the open fails.
  private func openForAppending() throws(JSONLFileError) -> Int32 {
    let path = url.path(percentEncoded: false)
    let (descriptor, errorNumber) = Self.retryingInterrupts {
      Darwin.open(path, Self.appendFlags, Self.newFileMode)
    }
    guard descriptor != Self.systemCallFailure else {
      throw .openFailed(errno: errorNumber)
    }
    return descriptor
  }

  /// Tells whether the file ends with a torn line: it is not empty, and its
  /// last byte is not `\n`. The check reads the last byte with `pread(2)`,
  /// which moves no file offset.
  ///
  /// - Parameter descriptor: The descriptor of the file, open for reading.
  /// - Returns: `true` when the next write must start with a `\n`.
  /// - Throws: ``JSONLFileError/tailCheckFailed(errno:)`` when the `fstat(2)`
  ///   or the `pread(2)` fails.
  private func endsWithTornLine(_ descriptor: Int32) throws(JSONLFileError) -> Bool {
    var status = stat()
    guard fstat(descriptor, &status) != Self.systemCallFailure else {
      throw .tailCheckFailed(errno: errno)
    }
    guard status.st_size > 0 else {
      return false
    }
    var lastByte = Self.newline
    let (count, errorNumber) = Self.retryingInterrupts {
      pread(descriptor, &lastByte, MemoryLayout<UInt8>.size, status.st_size - 1)
    }
    guard count != Self.systemCallFailure else {
      throw .tailCheckFailed(errno: errorNumber)
    }
    return lastByte != Self.newline
  }

  /// Gives `line` to one `write(2)`.
  ///
  /// - Parameters:
  ///   - line: The whole line, with its `\n`.
  ///   - descriptor: The descriptor of the file.
  /// - Throws: ``JSONLFileError/writeFailed(errno:)`` when the write fails,
  ///   or ``JSONLFileError/shortWrite(written:expected:)`` when it wrote
  ///   part of the line.
  private func write(_ line: Data, to descriptor: Int32) throws(JSONLFileError) {
    let (written, errorNumber) = line.withUnsafeBytes { bytes in
      Self.retryingInterrupts { calls.write(descriptor, bytes) }
    }
    guard written != Self.systemCallFailure else {
      throw .writeFailed(errno: errorNumber)
    }
    guard written == line.count else {
      throw .shortWrite(written: written, expected: line.count)
    }
  }

  /// Flushes the file to the disk with `fsync(2)`.
  ///
  /// - Parameter descriptor: The descriptor of the file.
  /// - Throws: ``JSONLFileError/syncFailed(errno:)`` when the sync fails.
  private func synchronize(_ descriptor: Int32) throws(JSONLFileError) {
    let (result, errorNumber) = Self.retryingInterrupts { calls.sync(descriptor) }
    guard result != Self.systemCallFailure else {
      throw .syncFailed(errno: errorNumber)
    }
  }

  /// Closes the descriptor of an append.
  ///
  /// - Parameter descriptor: The descriptor of the file.
  /// - Throws: ``JSONLFileError/closeFailed(errno:)`` when the close fails.
  private func close(_ descriptor: Int32) throws(JSONLFileError) {
    guard Darwin.close(descriptor) != Self.systemCallFailure else {
      throw .closeFailed(errno: errno)
    }
  }

  /// Runs a system call again while it fails with `EINTR`: a signal stopped
  /// it before it did anything.
  ///
  /// - Parameter call: The system call.
  /// - Returns: The result of the last run, and the `errno` right after it.
  private static func retryingInterrupts<Value: SignedInteger>(
    _ call: () -> Value
  ) -> (value: Value, errorNumber: Int32) {
    while true {
      let value = call()
      let errorNumber = errno
      guard value == systemCallFailure, errorNumber == EINTR else {
        return (value, errorNumber)
      }
    }
  }
}

/// A record of a ``JSONLFile`` that ``JSONLFile/fold(_:)`` folds by key: the
/// newest record of a key wins, and a tombstone removes the key.
public protocol JSONLKeyedRecord: Decodable {
  /// The type of the key.
  associatedtype Key: Hashable

  /// The key of the record.
  var key: Key { get }

  /// `true` when the record is a tombstone, which removes its key.
  var isTombstone: Bool { get }
}

/// The failures of a ``JSONLFile``.
public enum JSONLFileError: Error, Equatable, Sendable {
  /// The record of an append does not encode as JSON.
  case encodingFailed(description: String)

  /// The `open(2)` of an append failed with this `errno`, for example
  /// `ENOENT` when the folder of the file is not there.
  case openFailed(errno: Int32)

  /// The `fstat(2)` or the `pread(2)` that checks the last byte of the file
  /// before an append failed with this `errno`.
  case tailCheckFailed(errno: Int32)

  /// The `write(2)` of an append failed with this `errno`.
  case writeFailed(errno: Int32)

  /// The `write(2)` of an append wrote only part of the line, for example on
  /// a full disk. The part is on disk as a torn line.
  case shortWrite(written: Int, expected: Int)

  /// The `fsync(2)` of an append failed with this `errno`.
  case syncFailed(errno: Int32)

  /// The `close(2)` of an append failed with this `errno`. The line is on
  /// disk.
  case closeFailed(errno: Int32)

  /// The file exists and does not read.
  case readFailed(description: String)
}
