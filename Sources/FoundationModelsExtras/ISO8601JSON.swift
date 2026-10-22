import Foundation

/// The one setup of the JSON coders that write and read dates as ISO 8601
/// text in UTC with milliseconds, for example `2026-10-22T10:58:03.123Z`.
/// `JSONLFile` and the state file of the `Marketplace` module make their
/// coders here. `package` access, so a module of this package can call it and
/// a client of the package cannot.
///
/// The text is the form of ``DateTime``: the encoder rounds each date to the
/// nearest millisecond, so two dates in one second keep their order on disk.
/// The decoder reads only that text; a date with whole seconds only does not
/// decode. The coders share no mutable formatter, so they are safe on any
/// thread.
package enum ISO8601JSON {
  /// Makes an encoder that writes each date as ISO 8601 text with
  /// milliseconds.
  ///
  /// - Parameter outputFormatting: The output formatting of the encoder.
  /// - Returns: A new encoder.
  package static func makeEncoder(outputFormatting: JSONEncoder.OutputFormatting) -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
      try DateTime(date).encode(to: encoder)
    }
    encoder.outputFormatting = outputFormatting
    return encoder
  }

  /// Makes a decoder that reads each date from ISO 8601 text in UTC with
  /// milliseconds, the text that the encoder writes.
  ///
  /// - Returns: A new decoder. A date that is not that text throws
  ///   `DecodingError.dataCorrupted`.
  package static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom(decodeDate)
    return decoder
  }

  /// The description of the error of a date that is not the text that the
  /// encoder writes.
  private static let notMillisecondTextDescription =
    "The date is not ISO 8601 text in UTC with milliseconds."

  /// Decodes one date from the text that the encoder writes: ISO 8601 in UTC
  /// with milliseconds.
  ///
  /// The parser of ``DateTime`` also takes text with whole seconds only, so
  /// the text must also be the exact text that the date writes back.
  ///
  /// - Parameter decoder: The decoder that holds the text.
  /// - Returns: The date of the text.
  /// - Throws: `DecodingError.dataCorrupted` when the text is not ISO 8601
  ///   in UTC with milliseconds, or the error of the decoder when the value
  ///   is not a string.
  private static func decodeDate(from decoder: any Decoder) throws -> Date {
    let container = try decoder.singleValueContainer()
    let text = try container.decode(String.self)
    guard let time = try? DateTime(rfc3339: text), time.rfc3339 == text else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: notMillisecondTextDescription)
    }
    return time.date
  }
}
