import Foundation

/// The one setup of the JSON coders that write and read dates as ISO 8601
/// text. `JSONLFile` and the state file of the `Marketplace` module make
/// their coders here. `package` access, so a module of this package can call
/// it and a client of the package cannot.
package enum ISO8601JSON {
  /// Makes an encoder that writes each date as ISO 8601 text.
  ///
  /// - Parameter outputFormatting: The output formatting of the encoder.
  /// - Returns: A new encoder.
  package static func makeEncoder(outputFormatting: JSONEncoder.OutputFormatting) -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = outputFormatting
    return encoder
  }

  /// Makes a decoder that reads each date from ISO 8601 text.
  ///
  /// - Returns: A new decoder.
  package static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
