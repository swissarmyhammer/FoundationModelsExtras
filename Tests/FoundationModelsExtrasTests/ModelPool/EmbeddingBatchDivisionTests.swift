@testable import FoundationModelsExtras
import Testing

/// The division of the token rows of one embed call into sub-batches: the rows
/// are sorted by token count, each sub-batch keeps (rows) x (longest row) in the
/// token budget, a row longer than the budget goes alone and in full, and the
/// vectors go back in the input order.
///
/// The import is `@testable`, so a test can make the internal division type.
@Suite("Embedding batch division: sub-batches of rows of similar length, in a token budget")
struct EmbeddingBatchDivisionTests {
    /// The pad token of the padding check.
    private static let padToken = 0

    /// A token budget that the rows of a test do not fill.
    private static let largeBudget = 1_000

    /// A token budget of two rows of ``shortLength`` tokens.
    private static let smallBudget = 4

    /// The token count of a short row.
    private static let shortLength = 2

    /// The token count of a medium row: more than ``shortLength``, and not
    /// more than ``smallBudget``.
    private static let mediumLength = 3

    /// The token count of a long row: more than ``smallBudget``.
    private static let longLength = 9

    /// A row of `count` tokens. Each token is `marker`, so a test can tell the
    /// rows apart.
    private static func row(count: Int, marker: Int) -> [Int] {
        Array(repeating: marker, count: count)
    }

    @Test("the rows are sorted by token count, and rows of one count keep their input order")
    func rowsAreSortedByTokenCount() {
        let rows = [
            Self.row(count: Self.mediumLength, marker: 1), Self.row(count: Self.shortLength, marker: 2),
            Self.row(count: Self.mediumLength, marker: 3),
        ]

        let division = EmbeddingBatchDivision(rows: rows, tokenBudget: Self.largeBudget)

        #expect(division.subBatches.map(\.indices) == [[1, 0, 2]])
        #expect(division.subBatches.map(\.rows) == [[rows[1], rows[0], rows[2]]])
    }

    @Test("a sub-batch holds rows only while (rows) x (longest row) is in the token budget")
    func subBatchesStayInTheBudget() {
        let rows = (1...3).map { Self.row(count: Self.shortLength, marker: $0) }

        let division = EmbeddingBatchDivision(rows: rows, tokenBudget: Self.smallBudget)

        #expect(division.subBatches.map(\.indices) == [[0, 1], [2]])
    }

    @Test("a long row does not set the padded length of the short rows of a different sub-batch")
    func longRowDoesNotPadShortRows() throws {
        let rows = [
            Self.row(count: Self.longLength, marker: 1), Self.row(count: Self.shortLength, marker: 2),
            Self.row(count: Self.shortLength, marker: 3),
        ]

        let division = EmbeddingBatchDivision(rows: rows, tokenBudget: Self.smallBudget)
        let shortBatch = try #require(division.subBatches.first)
        let padding = EmbeddingBatchPadding(rows: shortBatch.rows, padToken: Self.padToken)

        #expect(shortBatch.indices == [1, 2])
        #expect(padding.tokens.map(\.count) == [Self.shortLength, Self.shortLength])
    }

    @Test("a row longer than the token budget goes in a sub-batch by itself, with all its tokens")
    func rowLongerThanTheBudgetGoesAloneInFull() {
        let long = Self.row(count: Self.longLength, marker: 1)
        let rows = [Self.row(count: Self.shortLength, marker: 2), long, Self.row(count: Self.longLength, marker: 3)]

        let division = EmbeddingBatchDivision(rows: rows, tokenBudget: Self.smallBudget)

        #expect(division.subBatches.map(\.indices) == [[0], [1], [2]])
        #expect(division.subBatches[1].rows == [long])
    }

    @Test("the vectors of the sub-batches go back in the input order of the rows")
    func vectorsGoBackInInputOrder() {
        let rows = [
            Self.row(count: Self.longLength, marker: 1), Self.row(count: Self.shortLength, marker: 2),
            Self.row(count: Self.mediumLength, marker: 3),
        ]
        let division = EmbeddingBatchDivision(rows: rows, tokenBudget: Self.smallBudget)
        let vectorsOfEachSubBatch = division.subBatches.map { $0.indices.map { "vector of row \($0)" } }

        let vectors = division.inInputOrder(vectorsOfEachSubBatch)

        #expect(vectors == ["vector of row 0", "vector of row 1", "vector of row 2"])
    }

    @Test("no rows give no sub-batches")
    func noRowsGiveNoSubBatches() {
        let division = EmbeddingBatchDivision(rows: [], tokenBudget: Self.smallBudget)

        #expect(division.subBatches.isEmpty)
    }
}
