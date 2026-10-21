extension InMemorySessionDirectory {
    /// The loop guards of session.md section 10.3, which the test double
    /// applies to each send. A UI sender and a session sender get the same
    /// guards.
    public struct LoopGuards: Sendable, Equatable {
        /// The default chain depth limit.
        public static let defaultChainDepthLimit = 3

        /// The bytes of one KB.
        static let bytesPerKilobyte = 1024

        /// The default message length limit in KB.
        static let defaultMessageKilobytes = 16

        /// The default message length limit: 16 KB of UTF-8.
        public static let defaultMessageLengthLimit = defaultMessageKilobytes * bytesPerKilobyte

        /// The default number of targets of one tag send.
        public static let defaultTagTargetLimit = 8

        /// The default number of sends from one turn.
        public static let defaultSendsPerTurnLimit = 16

        /// The deepest chain that a message can have. A send above it gives
        /// a `refused` receipt.
        public var chainDepthLimit: Int

        /// The longest message text, in UTF-8 bytes. A longer text throws
        /// ``SessionDirectoryError/messageTooLong(limit:)``.
        public var messageLengthLimit: Int

        /// The most targets that one tag send delivers to. The other targets
        /// get a `refused` receipt.
        public var tagTargetLimit: Int

        /// The most sends that one turn of a session can make. A later send
        /// of the same turn gives a `refused` receipt.
        public var sendsPerTurnLimit: Int

        /// Makes loop guards.
        ///
        /// - Parameters:
        ///   - chainDepthLimit: The deepest chain. The default is
        ///     ``defaultChainDepthLimit``.
        ///   - messageLengthLimit: The longest text, in UTF-8 bytes. The
        ///     default is ``defaultMessageLengthLimit``.
        ///   - tagTargetLimit: The most targets of one tag send. The default
        ///     is ``defaultTagTargetLimit``.
        ///   - sendsPerTurnLimit: The most sends of one turn. The default is
        ///     ``defaultSendsPerTurnLimit``.
        public init(
            chainDepthLimit: Int = Self.defaultChainDepthLimit,
            messageLengthLimit: Int = Self.defaultMessageLengthLimit,
            tagTargetLimit: Int = Self.defaultTagTargetLimit,
            sendsPerTurnLimit: Int = Self.defaultSendsPerTurnLimit
        ) {
            self.chainDepthLimit = chainDepthLimit
            self.messageLengthLimit = messageLengthLimit
            self.tagTargetLimit = tagTargetLimit
            self.sendsPerTurnLimit = sendsPerTurnLimit
        }
    }
}
