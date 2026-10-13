/// The generation options of one user message.
///
/// The session uses these options to batch the message and to select how
/// the answer is made. Router maps this type to its own submission options.
///
/// A guided session (a session with a grammar) never streams. Router
/// enforces this rule, not this type: a guided session gives a `stream`
/// message its text in the terminal event only.
public struct UserMessageOptions: Sendable, Codable, Hashable {
    /// How the session makes the answer.
    public enum Mode: String, Sendable, Codable, Hashable {
        /// The session gives the full text in the terminal event.
        case reply

        /// The session also sends the text in parts, as it makes it.
        case stream
    }

    /// The maximum number of tokens of the answer. `nil` means that the
    /// session uses its own limit.
    public var maxTokens: Int?

    /// How the session makes the answer.
    public var mode: Mode

    /// Makes the options.
    ///
    /// - Parameters:
    ///   - maxTokens: The maximum number of tokens of the answer. The
    ///     default is `nil`.
    ///   - mode: How the session makes the answer. The default is
    ///     ``Mode/reply``.
    public init(maxTokens: Int? = nil, mode: Mode = .reply) {
        self.maxTokens = maxTokens
        self.mode = mode
    }
}
