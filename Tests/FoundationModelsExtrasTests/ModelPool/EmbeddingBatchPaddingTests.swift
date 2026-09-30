@testable import FoundationModelsExtras
import Testing

/// The padding of one embed batch: each row is padded on the right to the
/// length of the longest row, and the mask of each row comes from its length,
/// not from its token values. Thus a real end token that equals the pad token
/// has a mask of 1.
///
/// The import is `@testable`, so a test can make the internal padding type.
@Suite("Embedding batch padding: right-padded rows and a mask from the length of each row")
struct EmbeddingBatchPaddingTests {
    /// The pad token. The tokenizer also adds it as the end token of each text.
    private static let padToken = 151_643

    /// The first real token of a row.
    private static let firstToken = 11

    /// The second real token of a row.
    private static let secondToken = 12

    /// The third real token of a row.
    private static let thirdToken = 13

    @Test("a short row gets pad tokens with a mask of 0, and its end token, which equals the pad token, has a mask of 1")
    func shortRowIsPaddedAndMaskedByLength() {
        let long = [Self.firstToken, Self.secondToken, Self.thirdToken, Self.padToken]
        let short = [Self.firstToken, Self.padToken]

        let padding = EmbeddingBatchPadding(rows: [long, short], padToken: Self.padToken)

        #expect(padding.tokens == [long, [Self.firstToken, Self.padToken, Self.padToken, Self.padToken]])
        #expect(padding.mask == [[1, 1, 1, 1], [1, 1, 0, 0]])
    }

    @Test("rows of one length get no pad tokens, and a mask of 1 for each token")
    func rowsOfOneLengthAreNotPadded() {
        let rows = [[Self.firstToken, Self.padToken], [Self.secondToken, Self.padToken]]

        let padding = EmbeddingBatchPadding(rows: rows, padToken: Self.padToken)

        #expect(padding.tokens == rows)
        #expect(padding.mask == [[1, 1], [1, 1]])
    }

    @Test("no rows give no tokens and no mask")
    func noRowsGiveAnEmptyPadding() {
        let padding = EmbeddingBatchPadding(rows: [], padToken: Self.padToken)

        #expect(padding.tokens.isEmpty)
        #expect(padding.mask.isEmpty)
    }
}
