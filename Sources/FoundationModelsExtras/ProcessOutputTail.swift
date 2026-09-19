import Foundation

/// A bounded accumulator for the merged output of a child process.
///
/// The read of a pipe gives the output in chunks, and a process can write
/// without end. This accumulator keeps the count of all the lines it has
/// seen, but it holds only the tail: at most `cap.lineCount` complete lines,
/// and at most `cap.byteLimit` bytes in total, the line in progress included.
/// When a line completes, or when the line in progress grows past the byte
/// limit, the oldest bytes go away at once, so the memory of the caller never
/// holds the full output.
///
/// A line ends at `\n`. A final newline adds no empty line, and a partial
/// last line counts as one line.
internal struct ProcessOutputTail {
  /// The output the accumulator kept when the read ended.
  internal struct Capture: Equatable, Sendable {
    /// The count of all the lines the process wrote, the dropped lines
    /// included.
    internal let lineCount: Int

    /// The lines the accumulator kept: the tail of the output, in arrival
    /// order, each decoded as UTF-8.
    internal let output: [String]

    /// `true` when at least one byte of the output went away because of
    /// the cap.
    internal let isTruncated: Bool
  }

  /// The byte that ends a line.
  private static let newline = UInt8(ascii: "\n")

  /// The limits this accumulator obeys.
  private let cap: ProcessRunner.OutputCap

  /// The complete lines the accumulator holds, with the dropped ones at the
  /// front replaced by empty data until `compactKeptLines()` removes them.
  private var lines: [Data] = []

  /// The index in `lines` of the oldest line that is still kept.
  private var firstKeptIndex = 0

  /// The sum of the byte counts of the kept complete lines.
  private var keptLineBytes = 0

  /// The bytes of the line in progress, which has no `\n` yet.
  private var partialLine = Data()

  /// The count of all the lines seen so far, the dropped lines included.
  private var lineCount = 0

  /// `true` when at least one byte went away because of the cap.
  private var isTruncated = false

  /// The count of bytes the accumulator holds now: the kept complete lines
  /// and the line in progress. Never more than `cap.byteLimit`.
  internal var retainedByteCount: Int {
    keptLineBytes + partialLine.count
  }

  /// Creates an empty accumulator that obeys `cap`.
  ///
  /// - Parameter cap: The line count and the byte limit to obey.
  internal init(cap: ProcessRunner.OutputCap) {
    self.cap = cap
  }

  /// Adds one chunk of output. The chunk can hold any count of lines, or a
  /// part of one line.
  ///
  /// - Parameter chunk: The bytes the read gave.
  internal mutating func append(_ chunk: Data) {
    var rest = chunk[...]
    while let newlineIndex = rest.firstIndex(of: Self.newline) {
      partialLine.append(rest[rest.startIndex..<newlineIndex])
      completeLine()
      rest = rest[rest.index(after: newlineIndex)...]
    }
    partialLine.append(rest)
    enforceCap()
  }

  /// Ends the read. A partial last line becomes a complete line.
  ///
  /// - Returns: The count of all the lines, the kept tail, and the mark.
  internal mutating func finish() -> Capture {
    if !partialLine.isEmpty {
      completeLine()
    }
    let output = lines[firstKeptIndex...].map { String(decoding: $0, as: UTF8.self) }
    return Capture(lineCount: lineCount, output: output, isTruncated: isTruncated)
  }

  /// Moves the line in progress to the kept lines, then applies the cap.
  private mutating func completeLine() {
    lineCount += 1
    lines.append(partialLine)
    keptLineBytes += partialLine.count
    partialLine = Data()
    enforceCap()
  }

  /// Cuts the line in progress to the byte limit, then drops the oldest
  /// complete lines until the line count and the byte limit both hold.
  private mutating func enforceCap() {
    if partialLine.count > cap.byteLimit {
      partialLine = Data(partialLine.suffix(cap.byteLimit))
      isTruncated = true
    }
    while firstKeptIndex < lines.count && isOverTheCap {
      dropOldestLine()
    }
    compactKeptLines()
  }

  /// `true` when the kept lines are more than the line count, or when the
  /// kept bytes are more than the byte limit.
  private var isOverTheCap: Bool {
    lines.count - firstKeptIndex > cap.lineCount || retainedByteCount > cap.byteLimit
  }

  /// Drops the oldest kept line and marks the output as cut.
  private mutating func dropOldestLine() {
    keptLineBytes -= lines[firstKeptIndex].count
    lines[firstKeptIndex] = Data()
    firstKeptIndex += 1
    isTruncated = true
  }

  /// Removes the dropped slots at the front of `lines` when they are more
  /// than the kept lines, so each drop costs constant time on average.
  private mutating func compactKeptLines() {
    guard firstKeptIndex > lines.count - firstKeptIndex else { return }
    lines.removeFirst(firstKeptIndex)
    firstKeptIndex = 0
  }
}
