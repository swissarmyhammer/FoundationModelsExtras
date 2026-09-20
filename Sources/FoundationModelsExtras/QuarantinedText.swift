import Foundation

/// Text in spans, where each span records where its text came from.
///
/// A consumer whose own format has more than one pass uses this type to
/// keep the rule that no pass scans the text of an earlier pass. An
/// `.original` span is source text, which the next pass may scan. A
/// `.quarantined` span is text that an earlier pass put in place of a
/// match; each later pass copies it and never scans it.
///
/// `StenciledDotfolderStack.render(_:in:)` is the last pass of such a
/// chain: it renders the text with Stencil, and it gives each
/// `.quarantined` span to Stencil as a value, never as template text.
public struct QuarantinedText: Sendable, Equatable {
  /// One run of text, with the record of where it came from.
  public enum Span: Sendable, Equatable {
    /// Source text, or text that an earlier pass did not touch. The next
    /// pass may scan it.
    case original(String)

    /// Text that an earlier pass put in place of a match. Each later pass
    /// copies it and never scans it.
    case quarantined(String)

    /// The text of this span, whatever its record.
    var text: String {
      switch self {
      case .original(let text), .quarantined(let text): return text
      }
    }
  }

  /// The spans of this text, in order.
  public var spans: [Span]

  /// Holds `spans`, made regular: each empty span is dropped, and the
  /// adjacent `.original` spans become one span.
  ///
  /// An empty `.quarantined` span carries no text for a later pass to
  /// protect, thus to keep it would only cut the `.original` text around it
  /// into two spans. That cut is what lets an untrusted text make spans for
  /// free: a text with many matches whose value is empty would otherwise
  /// reach the last pass as that many spans. To drop the empty span here,
  /// and to join the `.original` text on each side of it, keeps the edge of
  /// a span meaningful: there is an edge only where text that a pass put in
  /// place of a match sits.
  ///
  /// - Parameter spans: The spans to hold, in order.
  public init(spans: [Span]) {
    self.spans = Self.normalized(spans)
  }

  /// Holds `text` as one `.original` span, the start of a chain of passes.
  ///
  /// - Parameter text: The source text.
  public init(original text: String) {
    self.init(spans: [.original(text)])
  }

  /// Drops each empty span of `spans` and joins each run of adjacent
  /// `.original` spans into one span.
  ///
  /// Two adjacent `.quarantined` spans stay apart: each one is one match,
  /// and no later step reads two of them as one.
  ///
  /// - Parameter spans: The spans to make regular, in order.
  /// - Returns: The regular spans.
  private static func normalized(_ spans: [Span]) -> [Span] {
    var result: [Span] = []
    for span in spans where !span.text.isEmpty {
      if case .original(let text) = span, case .original(let previous)? = result.last {
        result[result.count - 1] = .original(previous + text)
      } else {
        result.append(span)
      }
    }
    return result
  }

  /// The text of each span, joined, with no record of where it came from.
  ///
  /// This is the result of the chain, when each pass has run.
  public var flattened: String {
    spans.map(\.text).joined()
  }

  /// Runs `transform` on the text of each `.original` span, and puts the
  /// spans that `transform` gives in place of that span. Each
  /// `.quarantined` span is copied: `transform` never sees it.
  ///
  /// This is the one seam that a pass uses to keep the rule that no pass
  /// scans the text of an earlier pass. A pass calls this method one time,
  /// with its own scan as `transform`, and it never reads `spans` itself.
  ///
  /// - Parameter transform: Cuts the text of one `.original` span into the
  ///   spans that take its place. Usually this is a run of `.original`
  ///   spans (text that the pass did not touch) and `.quarantined` spans
  ///   (text that the pass put in place of a match), which `SpanBuilder`
  ///   collects.
  /// - Returns: A new `QuarantinedText`, where the spans of `transform`
  ///   take the place of each `.original` span, in the same order.
  /// - Throws: What `transform` throws.
  public func mappingOriginalSpans(_ transform: (String) throws -> [Span]) rethrows
    -> QuarantinedText
  {
    try mappingOriginalSpans { text, _ in try transform(text) }
  }

  /// Runs `transform` on the text of each `.original` span together with
  /// the character before that span in the joined text, and puts the spans
  /// that `transform` gives in place of that span. Each `.quarantined` span
  /// is copied: `transform` never sees its text.
  ///
  /// The character before a span is the last character of the span that
  /// comes immediately before it, `.original` or `.quarantined`, or `nil`
  /// for the first span. It is there for a grammar whose match depends on
  /// what comes *before* the position of the match, for example a match
  /// that must start a line or must follow a space. To scan a span alone
  /// would read the start of each span as the start of the text, thus a
  /// span could make a position in the middle of a word into a position at
  /// the start of a line. To give the pass the true character before the
  /// span lets it read the joined text without a scan of the
  /// `.quarantined` text that this character came from.
  ///
  /// - Parameter transform: Cuts the text of one `.original` span, with the
  ///   character before it in the joined text, into the spans that take its
  ///   place.
  /// - Returns: A new `QuarantinedText`, where the spans of `transform`
  ///   take the place of each `.original` span, in the same order.
  /// - Throws: What `transform` throws.
  public func mappingOriginalSpans(
    _ transform: (_ text: String, _ precedingCharacter: Character?) throws -> [Span]
  ) rethrows -> QuarantinedText {
    var mapped: [Span] = []
    for (span, precedingCharacter) in spansWithPrecedingCharacters {
      switch span {
      case .original(let text): mapped += try transform(text, precedingCharacter)
      case .quarantined: mapped.append(span)
      }
    }
    return QuarantinedText(spans: mapped)
  }

  /// The same walk as `mappingOriginalSpans(_:)`, for a `transform` that
  /// suspends.
  ///
  /// A pass that waits, for example one that runs a child process for each
  /// match, has an `async` transform. Swift has no `reasync`, thus one
  /// method cannot serve a transform that suspends and a transform that
  /// does not. The two walks share `spansWithPrecedingCharacters`, which
  /// holds all of the bookkeeping.
  ///
  /// The label `awaiting:` keeps the two apart at each call, thus no caller
  /// must know which one the compiler took.
  ///
  /// - Parameter transform: Cuts the text of one `.original` span, with the
  ///   character before it in the joined text, into the spans that take its
  ///   place.
  /// - Returns: A new `QuarantinedText`, where the spans of `transform`
  ///   take the place of each `.original` span, in the same order.
  /// - Throws: What `transform` throws.
  public func mappingOriginalSpans(
    awaiting transform: (_ text: String, _ precedingCharacter: Character?) async throws -> [Span]
  ) async rethrows -> QuarantinedText {
    var mapped: [Span] = []
    for (span, precedingCharacter) in spansWithPrecedingCharacters {
      switch span {
      case .original(let text): mapped += try await transform(text, precedingCharacter)
      case .quarantined: mapped.append(span)
      }
    }
    return QuarantinedText(spans: mapped)
  }

  /// Each span of this text, with the character before it in the joined
  /// text; `nil` for the first span.
  ///
  /// A `.quarantined` span gives its last character to the span that comes
  /// after it, thus a pass reads the joined text through this list without
  /// a scan of the quarantined text itself.
  private var spansWithPrecedingCharacters: [(span: Span, precedingCharacter: Character?)] {
    var precedingCharacter: Character?
    var pairs: [(span: Span, precedingCharacter: Character?)] = []
    for span in spans {
      pairs.append((span, precedingCharacter))
      precedingCharacter = span.text.last ?? precedingCharacter
    }
    return pairs
  }
}

/// Collects the spans that take the place of one `.original` span, while a
/// pass scans that span from the left to the right: the runs of text with no
/// match become `.original` spans, and the text that the pass puts in place
/// of each match becomes its own `.quarantined` span.
///
/// A pass that splices text into its own scan uses this type, so that it
/// holds no bookkeeping of the literal runs itself.
public struct SpanBuilder {
  /// The spans collected so far.
  private var spans: [QuarantinedText.Span] = []

  /// The run of text with no match, collected so far.
  private var literal = ""

  /// Creates a builder with no span.
  public init() {}

  /// Adds `text` to the run of text with no match.
  ///
  /// - Parameter text: Text with no match, which the pass carries through
  ///   as `.original`.
  public mutating func appendOriginal<S: StringProtocol>(_ text: S) {
    literal += text
  }

  /// Closes the run of text with no match, then adds `value` as its own
  /// `.quarantined` span.
  ///
  /// An empty `value` adds nothing and keeps the run of text open, thus the
  /// text on each side of an empty value stays one `.original` span. This
  /// is the rule that `QuarantinedText.init(spans:)` applies, applied here
  /// before the cut is made.
  ///
  /// - Parameter value: The text that the pass put in place of a match.
  public mutating func appendQuarantined(_ value: String) {
    guard !value.isEmpty else { return }
    flushLiteral()
    spans.append(.quarantined(value))
  }

  /// Closes the run of text with no match and gives the spans.
  ///
  /// - Returns: Each span added so far, in order.
  public mutating func finish() -> [QuarantinedText.Span] {
    flushLiteral()
    return spans
  }

  /// Adds the run of text with no match as an `.original` span, if it holds
  /// text, and starts a new run.
  private mutating func flushLiteral() {
    guard !literal.isEmpty else { return }
    spans.append(.original(literal))
    literal = ""
  }
}
