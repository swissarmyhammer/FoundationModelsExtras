/// The token rows of one embed batch, padded on the right to one length, and
/// the attention mask of each row.
///
/// The mask comes from the length of each row, not from the token values. A
/// tokenizer can use its end token as the pad token, and it adds that end token
/// to each text. A mask of `token != padToken` then removes the real end token
/// too. Here each real token has a mask of ``realToken`` and each pad has a mask
/// of ``padding``, whatever its value.
struct EmbeddingBatchPadding: Equatable {
    /// The mask value of a real token: the model attends to it, and the
    /// pooling reads it.
    static let realToken = 1

    /// The mask value of a pad: the model does not attend to it, and the
    /// pooling does not read it.
    static let padding = 0

    /// Each row, padded on the right with the pad token to the length of the
    /// longest row.
    let tokens: [[Int]]

    /// The mask of each row of ``tokens``: ``realToken`` for each token of the
    /// original row, then ``padding`` for each pad.
    let mask: [[Int]]

    /// Pads `rows` on the right to the length of the longest row, and makes the
    /// mask of each row from its length.
    ///
    /// - Parameters:
    ///   - rows: The token rows of the batch, in order.
    ///   - padToken: The token that fills each row after its last real token.
    init(rows: [[Int]], padToken: Int) {
        let length = rows.map(\.count).max() ?? 0
        tokens = rows.map { Self.extended(row: $0, toLength: length, with: padToken) }
        mask = rows.map {
            Self.extended(
                row: Array(repeating: Self.realToken, count: $0.count), toLength: length, with: Self.padding)
        }
    }

    /// Adds copies of `value` to the end of `row` until it has `length` items.
    ///
    /// - Parameters:
    ///   - row: The row to extend. It has `length` items or fewer.
    ///   - length: The length of the result.
    ///   - value: The value that fills the end of the row.
    /// - Returns: `row`, then `value` for each missing item.
    private static func extended(row: [Int], toLength length: Int, with value: Int) -> [Int] {
        row + Array(repeating: value, count: length - row.count)
    }
}
