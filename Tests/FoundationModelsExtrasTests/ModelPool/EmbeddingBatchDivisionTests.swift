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

    /// The sub-batches of the rows of ``theStatisticsOfACall()`` in
    /// ``smallBudget``: the two short rows, the medium row, and the long row.
    private static let subBatchesOfTheCallStatistics = 3

    /// The rows of ``theStatisticsOfACall()`` that are longer than
    /// ``smallBudget``: the long row.
    private static let rowsOverTheSmallBudget = 1

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

    @Test("the division keeps its token budget")
    func theDivisionKeepsItsTokenBudget() {
        let division = EmbeddingBatchDivision(rows: [], tokenBudget: Self.smallBudget)

        #expect(division.tokenBudget == Self.smallBudget)
    }

    @Test("the statistics of a call give the text count, the token count, the longest row, the sub-batch count and the rows over the budget")
    func theStatisticsOfACall() {
        let rows = [
            Self.row(count: Self.longLength, marker: 1), Self.row(count: Self.shortLength, marker: 2),
            Self.row(count: Self.mediumLength, marker: 3), Self.row(count: Self.shortLength, marker: 4),
        ]

        let statistics = EmbeddingBatchStatistics(of: EmbeddingBatchDivision(rows: rows, tokenBudget: Self.smallBudget))

        #expect(statistics.textCount == rows.count)
        #expect(statistics.tokenCount == Self.longLength + Self.shortLength + Self.mediumLength + Self.shortLength)
        #expect(statistics.maxTokens == Self.longLength)
        #expect(statistics.subBatchCount == Self.subBatchesOfTheCallStatistics)
        #expect(statistics.overBudgetRows == Self.rowsOverTheSmallBudget)
    }

    @Test("the statistics of a sub-batch give its rows, its longest row, its padded tokens and its pad ratio")
    func theStatisticsOfASubBatch() throws {
        let rows = [Self.row(count: Self.shortLength, marker: 1), Self.row(count: Self.mediumLength, marker: 2)]

        let statistics = EmbeddingBatchStatistics(of: EmbeddingBatchDivision(rows: rows, tokenBudget: Self.largeBudget))
        let subBatch = try #require(statistics.subBatches.first)

        let paddedTokens = rows.count * Self.mediumLength
        let padTokens = paddedTokens - (Self.shortLength + Self.mediumLength)
        #expect(statistics.subBatches.count == statistics.subBatchCount)
        #expect(
            subBatch
                == EmbeddingBatchStatistics.SubBatch(
                    rows: rows.count, longestRow: Self.mediumLength, paddedTokens: paddedTokens,
                    padRatio: Double(padTokens) / Double(paddedTokens)))
    }

    @Test("the statistics of no rows are all zero, and a sub-batch with no tokens has no padding")
    func theStatisticsOfNoRows() {
        let noTokens = EmbeddingBatchStatistics.SubBatch(of: EmbeddingBatchDivision.SubBatch(indices: [0], rows: [[]]))

        let statistics = EmbeddingBatchStatistics(of: EmbeddingBatchDivision(rows: [], tokenBudget: Self.smallBudget))

        #expect(statistics.textCount == 0)
        #expect(statistics.tokenCount == 0)
        #expect(statistics.maxTokens == 0)
        #expect(statistics.subBatchCount == 0)
        #expect(statistics.overBudgetRows == 0)
        #expect(noTokens.paddedTokens == 0)
        #expect(noTokens.padRatio == 0)
    }
}
