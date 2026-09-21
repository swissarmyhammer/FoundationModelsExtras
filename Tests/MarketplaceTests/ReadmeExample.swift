import FixtureSupport
import Foundation
import Testing

/// Reads the two copies of a README example: the fenced Swift block under a
/// README heading, and the code between two marker comments of a test file.
///
/// A test that holds a README example proves that the two copies are the
/// same text, line for line. The comparison removes the leading and trailing
/// whitespace of each line, thus the README can indent the example in its
/// own style, but it cannot drift from the code that compiles and runs.
enum ReadmeExample {
  /// The line that opens a fenced Swift block.
  private static let fenceOpening = "```swift"

  /// The line that closes a fenced block.
  private static let fenceClosing = "```"

  /// The lines of the first fenced Swift block under `heading` in
  /// `README.md`, with the whitespace of each line trimmed.
  ///
  /// - Parameter heading: The heading line of the README section.
  /// - Returns: The lines between the fence that opens the block and the
  ///   fence that closes it.
  /// - Throws: A failed requirement when the README has no such heading, or
  ///   no fenced Swift block after it.
  static func readmeLines(under heading: String) throws -> [String] {
    let lines = trimmedLines(ofText: try FixtureFile.text(MarketplaceTestSupport.readmePath).get())
    let headingIndex = try #require(lines.firstIndex(of: heading))
    let opening = try #require(lines[headingIndex...].firstIndex(of: fenceOpening))
    let closing = try #require(lines[opening...].dropFirst().firstIndex(of: fenceClosing))
    return Array(lines[(opening + 1)..<closing])
  }

  /// The lines between two marker comments of a test file, with the
  /// whitespace of each line trimmed.
  ///
  /// - Parameters:
  ///   - start: The comment line that starts the example.
  ///   - end: The comment line that ends the example.
  ///   - file: The path of the test file. The default is the file of the
  ///     caller.
  /// - Returns: The lines between the start marker and the end marker.
  /// - Throws: A failed requirement when a marker is not there, else the
  ///   error of the file read.
  static func lines(between start: String, and end: String, inFile file: String = #filePath) throws -> [String] {
    let lines = trimmedLines(ofText: try String(contentsOfFile: file, encoding: .utf8))
    let startIndex = try #require(lines.firstIndex(of: start))
    let endIndex = try #require(lines[startIndex...].firstIndex(of: end))
    return Array(lines[(startIndex + 1)..<endIndex])
  }

  /// Splits `text` into lines, with the leading and trailing whitespace of
  /// each line removed.
  ///
  /// - Parameter text: The text to split.
  /// - Returns: One entry for each line.
  private static func trimmedLines(ofText text: String) -> [String] {
    text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
  }
}
