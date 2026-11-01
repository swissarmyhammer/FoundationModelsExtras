import Foundation

/// One text and the token ids that the Python `tokenizers` library gives for it.
struct ReferenceTokenCase {
    /// The text to tokenize.
    let text: String

    /// The ids of the real tokens, as the Python library gives them with
    /// special tokens, and with truncation to the model length. The pad ids
    /// after them are not listed.
    let ids: [Int32]
}

/// The pad id that the Python library gave for the `<pad>` token.
let referencePadToken: Int32 = 0

/// The model length that the Python library padded and truncated to.
let referenceLength = 128

/// The reference cases, made by this Python code on the `tokenizer.json` of
/// `erjigit17/embeddinggemma-300m-ane-coreml`:
///
///     tokenizer = Tokenizer.from_file("tokenizer.json")
///     tokenizer.enable_truncation(max_length=128)
///     tokenizer.enable_padding(length=128, pad_id=tokenizer.token_to_id("<pad>"))
///     encoding = tokenizer.encode(text)
///     ids = [i for i, m in zip(encoding.ids, encoding.attention_mask) if m]
let referenceTokenCases: [ReferenceTokenCase] = [
    ReferenceTokenCase(
        text: "hello",
        ids: [
            2, 23391, 1,
        ]),
    ReferenceTokenCase(
        text: "task: search result | query: How do I keep a cat warm in winter?",
        ids: [
            2, 8071, 236787, 3927, 1354, 1109, 7609, 236787, 2088, 776, 564, 2514, 496, 5866, 6962, 528,
            7208, 236881, 1,
        ]),
    ReferenceTokenCase(
        text: "title: none | text: A cat likes to sleep on a warm windowsill or on a heated pad.",
        ids: [
            2, 3250, 236787, 7293, 1109, 1816, 236787, 562, 5866, 15975, 531, 6745, 580, 496, 6962, 191646,
            653, 580, 496, 20067, 8392, 236761, 1,
        ]),
    ReferenceTokenCase(
        text: "title: none | text: " + (1...400).map { "word\($0)" }.joined(separator: " "),
        ids: [
            2, 3250, 236787, 7293, 1109, 1816, 236787, 3658, 236770, 3658, 236778, 3658, 236800, 3658, 236812, 3658,
            236810, 3658, 236825, 3658, 236832, 3658, 236828, 3658, 236819, 3658, 236770, 236771, 3658, 236770, 236770, 3658,
            236770, 236778, 3658, 236770, 236800, 3658, 236770, 236812, 3658, 236770, 236810, 3658, 236770, 236825, 3658, 236770,
            236832, 3658, 236770, 236828, 3658, 236770, 236819, 3658, 236778, 236771, 3658, 236778, 236770, 3658, 236778, 236778,
            3658, 236778, 236800, 3658, 236778, 236812, 3658, 236778, 236810, 3658, 236778, 236825, 3658, 236778, 236832, 3658,
            236778, 236828, 3658, 236778, 236819, 3658, 236800, 236771, 3658, 236800, 236770, 3658, 236800, 236778, 3658, 236800,
            236800, 3658, 236800, 236812, 3658, 236800, 236810, 3658, 236800, 236825, 3658, 236800, 236832, 3658, 236800, 236828,
            3658, 236800, 236819, 3658, 236812, 236771, 3658, 236812, 236770, 3658, 236812, 236778, 3658, 236812, 236800, 1,
        ]),
    ReferenceTokenCase(
        text: "日本語のテキストです。猫は暖かい場所が好きです。",
        ids: [
            2, 94951, 236945, 95830, 3652, 236924, 239959, 237048, 233544, 38147, 191062, 3652, 236924, 1,
        ]),
    ReferenceTokenCase(
        text: "task: search result | query: Où puis-je trouver un café près de la gare ? Straße, naïve, Zürich — ñandú",
        ids: [
            2, 8071, 236787, 3927, 1354, 1109, 7609, 236787, 75523, 21987, 236772, 1956, 34039, 723, 33443, 28827,
            569, 759, 111550, 2360, 80176, 236764, 120362, 236764, 116315, 2192, 131079, 624, 237066, 1,
        ]),
    ReferenceTokenCase(
        text: "  leading and trailing spaces  \n\ttab and newline ",
        ids: [
            2, 138, 26016, 532, 45330, 9952, 138, 107, 255968, 4823, 532, 100837, 236743, 1,
        ]),
]
