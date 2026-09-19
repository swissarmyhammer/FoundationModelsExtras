/// A dotfolder document split into its frontmatter and its body: the item
/// that `FrontmatterDocumentStack` gives back for one file.
///
/// `Metadata` is what the consumer decodes the frontmatter text into. The
/// split holds no knowledge of YAML (plan.md §4): the consumer gives the
/// decode, and Extras gives a default decode into `YAMLValue`.
///
/// The split itself is `split(text:)`, a purely textual fence recognition.
/// A frontmatter block is recognized only when the very first line of the
/// text is exactly `---` and a later line is also exactly `---`; the raw text
/// between those two fence lines (including any trailing line terminator) is
/// the frontmatter, and everything after the closing fence's line terminator
/// is the body. Any other shape — no leading fence, or a leading fence with
/// no closing fence — yields the entire input back as the body.
public struct FrontmatterDocument<Metadata: Sendable>: Sendable {
  /// The decoded frontmatter, or `nil` when the text holds no frontmatter
  /// block or the decode failed.
  public var metadata: Metadata?

  /// The text after the closing fence, byte for byte. The full text when
  /// there is no frontmatter block.
  public var content: String

  /// Creates a document. Exposed publicly so that a consumer can build
  /// fixtures and fakes with a plain `import FoundationModelsExtras`.
  ///
  /// - Parameters:
  ///   - metadata: The decoded frontmatter, or `nil`.
  ///   - content: The text after the closing fence.
  public init(metadata: Metadata?, content: String) {
    self.metadata = metadata
    self.content = content
  }
}

/// The textual split. It needs no metadata type, thus it is placed on
/// `FrontmatterDocument<Never>` so that a caller writes
/// `FrontmatterDocument.split(text:)` with no generic argument.
extension FrontmatterDocument where Metadata == Never {
  /// The literal fence line that opens and closes a frontmatter block.
  private static var fence: Substring { "---" }

  /// Splits `text` into an optional frontmatter block and a body.
  ///
  /// - Parameter text: The raw document text, LF or CRLF line endings, to
  ///   split.
  /// - Returns: `frontmatter` is `nil` when no frontmatter block is
  ///   present (including an unterminated opening fence), or the raw text
  ///   between the fences (possibly empty) otherwise. `body` is always the
  ///   remaining text, preserved byte-for-byte.
  public static func split(text: String) -> (frontmatter: String?, body: String) {
    let (firstLineEnd, afterFirstLine) = lineBounds(in: text, from: text.startIndex)
    guard text[text.startIndex..<firstLineEnd] == fence else {
      return (nil, text)
    }

    var lineStart = afterFirstLine
    while lineStart < text.endIndex {
      let (lineEnd, afterLine) = lineBounds(in: text, from: lineStart)
      if text[lineStart..<lineEnd] == fence {
        let frontmatter = String(text[afterFirstLine..<lineStart])
        let body = String(text[afterLine...])
        return (frontmatter, body)
      }
      lineStart = afterLine
    }

    // Opening fence with no matching close: the whole text is body.
    return (nil, text)
  }

  /// Finds the bounds of the line starting at `start`.
  ///
  /// - Returns: `contentEnd` is the index just before the line terminator
  ///   (or `text.endIndex` if the line has none); `afterTerminator` is the
  ///   index just past the terminator (equal to `contentEnd` if there is
  ///   none). Swift's `Character` already treats a CRLF pair as a single
  ///   grapheme cluster, so this walk handles CRLF and LF input alike
  ///   without special-casing either.
  private static func lineBounds(
    in text: String, from start: String.Index
  ) -> (contentEnd: String.Index, afterTerminator: String.Index) {
    var index = start
    while index < text.endIndex {
      let character = text[index]
      if character == "\n" || character == "\r\n" || character == "\r" {
        let contentEnd = index
        let afterTerminator = text.index(after: index)
        return (contentEnd, afterTerminator)
      }
      index = text.index(after: index)
    }
    return (text.endIndex, text.endIndex)
  }
}
