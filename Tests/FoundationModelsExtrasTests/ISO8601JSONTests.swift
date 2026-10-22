import Foundation
import Testing

@testable import FoundationModelsExtras

/// Proves the coders of `ISO8601JSON`: dates are ISO 8601 text with
/// fractional seconds both ways, a date with whole seconds only does not
/// read, and the encoder keeps the output formatting that its caller gives.
@Suite("ISO 8601 JSON")
struct ISO8601JSONTests {
  /// A record with a date and a text that holds a slash.
  private struct Stamp: Codable, Equatable {
    /// The date of the record.
    let at: Date

    /// A text with a slash, to show the output formatting.
    let path: String
  }

  /// The number of milliseconds in one second.
  private static let millisecondsPerSecond = 1000.0

  /// The milliseconds after the Unix epoch of the date of ``stamp``: less
  /// than one second, so only the fractional seconds hold them.
  private static let stampMilliseconds = 123.0

  /// The milliseconds since 1970 of a date of October 2026, with a part of a
  /// second, for the round trip.
  private static let roundTripMilliseconds = 1_792_234_683_457.0

  /// The record of the tests: a date a part of a second after the Unix
  /// epoch, and a path.
  private static let stamp = Stamp(
    at: Date(timeIntervalSince1970: stampMilliseconds / millisecondsPerSecond), path: "a/b")

  /// The JSON of ``stamp`` with sorted keys and slashes not escaped.
  private static let stampJSON = #"{"at":"1970-01-01T00:00:00.123Z","path":"a/b"}"#

  /// The JSON of a record whose date has whole seconds only.
  private static let wholeSecondJSON = #"{"at":"1970-01-01T00:00:00Z","path":"a/b"}"#

  /// The encoder writes each date as ISO 8601 text with fractional seconds,
  /// with the output formatting of its caller.
  @Test func encoderWritesISO8601DatesWithTheGivenFormatting() throws {
    let encoder = ISO8601JSON.makeEncoder(outputFormatting: [.sortedKeys, .withoutEscapingSlashes])
    let json = String(decoding: try encoder.encode(Self.stamp), as: UTF8.self)
    #expect(json == Self.stampJSON)
  }

  /// The decoder reads each date from ISO 8601 text with fractional seconds.
  @Test func decoderReadsISO8601Dates() throws {
    let decoded = try ISO8601JSON.makeDecoder().decode(Stamp.self, from: Data(Self.stampJSON.utf8))
    #expect(decoded == Self.stamp)
  }

  /// A date with a part of a second comes back from the encoder and the
  /// decoder with the same milliseconds.
  @Test func aDateRoundTripsAtMillisecondPrecision() throws {
    let stamp = Stamp(
      at: Date(timeIntervalSince1970: Self.roundTripMilliseconds / Self.millisecondsPerSecond),
      path: "a/b")
    let data = try ISO8601JSON.makeEncoder(outputFormatting: []).encode(stamp)

    let decoded = try ISO8601JSON.makeDecoder().decode(Stamp.self, from: data)

    #expect(decoded == stamp)
  }

  /// The decoder does not read a date with whole seconds only.
  @Test func decoderRejectsADateWithWholeSecondsOnly() {
    #expect(throws: DecodingError.self) {
      try ISO8601JSON.makeDecoder().decode(Stamp.self, from: Data(Self.wholeSecondJSON.utf8))
    }
  }
}
