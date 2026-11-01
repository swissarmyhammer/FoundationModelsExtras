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

/// The number of words in the long reference text. It is far more than the
/// model length, thus the text is cut.
private let longTextWordCount = 400

/// The error when the file of reference ids is not in the test bundle.
struct ReferenceTokenIdsMissing: Error {}

/// The reference cases, made by this Python code on the `tokenizer.json` of
/// `erjigit17/embeddinggemma-300m-ane-coreml`:
///
///     tokenizer = Tokenizer.from_file("tokenizer.json")
///     tokenizer.enable_truncation(max_length=128)
///     tokenizer.enable_padding(length=128, pad_id=tokenizer.token_to_id("<pad>"))
///     encoding = tokenizer.encode(text)
///     ids = [i for i, m in zip(encoding.ids, encoding.attention_mask) if m]
///
/// The ids are in the resource `ReferenceTokenIds.json`, a map from the name
/// of a case to its ids. The texts are here, with the same names.
private let referenceTexts: [(name: String, text: String)] = [
    ("short", "hello"),
    ("queryPrefix", "task: search result | query: How do I keep a cat warm in winter?"),
    ("documentPrefix", "title: none | text: A cat likes to sleep on a warm windowsill or on a heated pad."),
    (
        "long",
        "title: none | text: " + (1...longTextWordCount).map { "word\($0)" }.joined(separator: " ")
    ),
    ("japanese", "日本語のテキストです。猫は暖かい場所が好きです。"),
    (
        "multilingual",
        "task: search result | query: Où puis-je trouver un café près de la gare ? Straße, naïve, Zürich — ñandú"
    ),
    ("whitespace", "  leading and trailing spaces  \n\ttab and newline "),
]

/// Reads the reference cases: each text with the ids from the resource.
func loadReferenceTokenCases() throws -> [ReferenceTokenCase] {
    guard let url = Bundle.module.url(forResource: "ReferenceTokenIds", withExtension: "json") else {
        throw ReferenceTokenIdsMissing()
    }
    let idsByName = try JSONDecoder().decode([String: [Int32]].self, from: Data(contentsOf: url))
    return try referenceTexts.map { reference in
        guard let ids = idsByName[reference.name] else { throw ReferenceTokenIdsMissing() }
        return ReferenceTokenCase(text: reference.text, ids: ids)
    }
}
