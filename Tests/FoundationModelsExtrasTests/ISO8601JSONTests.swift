import Foundation
import Testing

@testable import FoundationModelsExtras

/// Proves the coders of `ISO8601JSON`: dates are ISO 8601 text both ways, and
/// the encoder keeps the output formatting that its caller gives.
@Suite("ISO 8601 JSON")
struct ISO8601JSONTests {
  /// A record with a date and a text that holds a slash.
  private struct Stamp: Codable, Equatable {
    /// The date of the record.
    let at: Date

    /// A text with a slash, to show the output formatting.
    let path: String
  }

  /// The record of the tests: the Unix epoch, and a path.
  private static let stamp = Stamp(at: Date(timeIntervalSince1970: 0), path: "a/b")

  /// The JSON of ``stamp`` with sorted keys and slashes not escaped.
  private static let stampJSON = #"{"at":"1970-01-01T00:00:00Z","path":"a/b"}"#

  /// The encoder writes each date as ISO 8601 text, with the output
  /// formatting of its caller.
  @Test func encoderWritesISO8601DatesWithTheGivenFormatting() throws {
    let encoder = ISO8601JSON.makeEncoder(outputFormatting: [.sortedKeys, .withoutEscapingSlashes])
    let json = String(decoding: try encoder.encode(Self.stamp), as: UTF8.self)
    #expect(json == Self.stampJSON)
  }

  /// The decoder reads each date from ISO 8601 text.
  @Test func decoderReadsISO8601Dates() throws {
    let decoded = try ISO8601JSON.makeDecoder().decode(Stamp.self, from: Data(Self.stampJSON.utf8))
    #expect(decoded == Self.stamp)
  }
}
