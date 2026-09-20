import Foundation
import Testing

@testable import FoundationModelsExtras

/// Behavioral tests for `QuarantinedText` and `SpanBuilder`: the
/// normalization of the spans, the two mapping seams, the character before
/// a span, the builder, and `flattened`.
@Suite struct QuarantinedTextTests {
  /// An error that a transform throws, to show that a mapping seam gives
  /// the error of its transform to its caller.
  private struct TransformFailure: Error {}

  /// A text that holds template syntax, which a `.quarantined` span keeps
  /// as data.
  private static let templateSyntax = "{{ secret }}"

  // MARK: - Normalization

  @Test func initSpansDropsEachEmptySpanAndJoinsTheAdjacentOriginalSpans() {
    let text = QuarantinedText(spans: [
      .original("a"), .original(""), .original("b"), .quarantined(""), .original("c"),
    ])

    #expect(text.spans == [.original("abc")])
  }

  @Test func initSpansKeepsTwoAdjacentQuarantinedSpansApart() {
    let text = QuarantinedText(spans: [.quarantined("a"), .quarantined("b")])

    #expect(text.spans == [.quarantined("a"), .quarantined("b")])
  }

  @Test func initOriginalWrapsTheWholeTextAsOneOriginalSpan() {
    #expect(QuarantinedText(original: "text").spans == [.original("text")])
    #expect(QuarantinedText(original: "").spans.isEmpty)
  }

  @Test func flattenedJoinsTheTextOfEachSpanInOrder() {
    let text = QuarantinedText(spans: [.original("a"), .quarantined("b"), .original("c")])

    #expect(text.flattened == "abc")
  }

  // MARK: - The mapping seams

  @Test func mappingOriginalSpansReplacesEachOriginalSpanAndCopiesEachQuarantinedSpan() {
    let text = QuarantinedText(spans: [
      .original("a"), .quarantined(Self.templateSyntax), .original("b"),
    ])

    let mapped = text.mappingOriginalSpans { spanText in [.quarantined(spanText.uppercased())] }

    #expect(
      mapped.spans == [
        .quarantined("A"), .quarantined(Self.templateSyntax), .quarantined("B"),
      ])
  }

  @Test func mappingOriginalSpansGivesEachOriginalSpanTheCharacterBeforeIt() {
    let text = QuarantinedText(spans: [.original("a"), .quarantined("XY"), .original("b")])
    var precedingCharacters: [Character?] = []

    _ = text.mappingOriginalSpans { spanText, precedingCharacter in
      precedingCharacters.append(precedingCharacter)
      return [.original(spanText)]
    }

    #expect(precedingCharacters == [nil, "Y"])
  }

  @Test func mappingOriginalSpansAwaitingWalksTheSpansTheSameWay() async {
    let text = QuarantinedText(spans: [.original("a"), .quarantined("XY"), .original("b")])

    let mapped = await text.mappingOriginalSpans(awaiting: { spanText, precedingCharacter in
      [.quarantined("\(precedingCharacter.map(String.init) ?? "-")\(spanText)")]
    })

    #expect(
      mapped.spans == [.quarantined("-a"), .quarantined("XY"), .quarantined("Yb")])
  }

  @Test func mappingOriginalSpansGivesTheErrorOfItsTransformToTheCaller() {
    let text = QuarantinedText(original: "a")

    #expect(throws: TransformFailure.self) {
      try text.mappingOriginalSpans { _ in throw TransformFailure() }
    }
  }

  // MARK: - The builder

  @Test func spanBuilderJoinsTheAdjacentLiteralRunsIntoOneOriginalSpan() {
    var builder = SpanBuilder()
    builder.appendOriginal("a")
    builder.appendOriginal("b")
    builder.appendQuarantined("Q")
    builder.appendOriginal("c")

    #expect(builder.finish() == [.original("ab"), .quarantined("Q"), .original("c")])
  }

  @Test func spanBuilderDropsAnEmptyValueAndKeepsTheLiteralRunWhole() {
    var builder = SpanBuilder()
    builder.appendOriginal("a")
    builder.appendQuarantined("")
    builder.appendOriginal("b")

    #expect(builder.finish() == [.original("ab")])
  }

  @Test func spanBuilderGivesNoSpanWhenNothingWasAppended() {
    var builder = SpanBuilder()

    #expect(builder.finish().isEmpty)
  }
}
