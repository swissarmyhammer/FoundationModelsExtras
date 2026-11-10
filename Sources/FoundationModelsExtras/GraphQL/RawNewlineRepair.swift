/// The repair of a raw line break in a quoted string of a document, before the parse.
///
/// A model often writes a document in a JavaScript template literal and puts `\n` in a `"…"` string value. JavaScript
/// turns it into a real line break, and the GraphQL lexer then fails with "Unterminated string", because the
/// specification forbids a line break in a string that is not a block string. The intent is clear, so the repair
/// gives each raw line break in such a string as the escape `\n`: a CR, an LF, and a CR LF each give one `\n`. A
/// block string `"""…"""` and a comment keep their line breaks. A document with a repair gives one warning.
///
/// The parse then reads the repaired text, so the locations of later errors are in the repaired text: a repaired
/// string is on one line.
enum RawNewlineRepair {
    /// The code of the warning of a repair.
    static let warningCode = "RAW_NEWLINE_IN_STRING"

    /// The warning of a document with a repair.
    static let warning = ResponseWarning(
        message: "A string value had a raw line break, which GraphQL does not allow outside a block string. The call "
            + "read it as \\n. Write \\n in the string, or use a block string (\"\"\"…\"\"\").",
        code: warningCode
    )

    /// Gives a document with each raw line break of a quoted string as the escape `\n`.
    ///
    /// - Parameter source: The text of the document.
    /// - Returns: The repaired text, and `true` when the repair changed the text.
    static func repaired(_ source: String) -> (text: String, changed: Bool) {
        let bytes = Array(source.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var changed = false
        var index = 0
        func copy(_ count: Int) {
            let end = min(index + count, bytes.count)
            output += bytes[index..<end]
            index = end
        }
        func isTripleQuote(at position: Int) -> Bool {
            bytes[position...].starts(with: tripleQuote)
        }
        func isLineBreakPair(at position: Int) -> Bool {
            bytes[position...].starts(with: lineBreakPair)
        }
        while index < bytes.count {
            switch bytes[index] {
            case hash:
                while index < bytes.count, bytes[index] != lineFeed, bytes[index] != carriageReturn {
                    copy(1)
                }
            case quote where isTripleQuote(at: index):
                copy(tripleQuote.count)
                while index < bytes.count, !isTripleQuote(at: index) {
                    let isEscaped = bytes[index] == backslash && isTripleQuote(at: index + 1)
                    copy(isEscaped ? 1 + tripleQuote.count : 1)
                }
                copy(tripleQuote.count)
            case quote:
                copy(1)
                while index < bytes.count, bytes[index] != quote {
                    switch bytes[index] {
                    case backslash:
                        copy(escapeLength)
                    case lineFeed, carriageReturn:
                        output += [backslash, letterN]
                        index += isLineBreakPair(at: index) ? lineBreakPair.count : 1
                        changed = true
                    default:
                        copy(1)
                    }
                }
                copy(1)
            default:
                copy(1)
            }
        }
        return changed ? (String(decoding: output, as: UTF8.self), true) : (source, false)
    }

    /// The bytes that the repair reads.
    private static let quote = UInt8(ascii: "\"")
    private static let backslash = UInt8(ascii: "\\")
    private static let hash = UInt8(ascii: "#")
    private static let lineFeed = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")
    private static let letterN = UInt8(ascii: "n")

    /// The bounds of a block string.
    private static let tripleQuote = [quote, quote, quote]

    /// The CR LF line break, which gives one `\n`.
    private static let lineBreakPair = [carriageReturn, lineFeed]

    /// The length of an escape in a quoted string: the backslash and the escaped byte. The bytes of a `\u` escape
    /// after its `u` are plain bytes of the string.
    private static let escapeLength = 2
}
