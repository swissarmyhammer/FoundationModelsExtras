import Foundation
import ULID

/// A message that the directory delivered to one session.
public struct SessionMessage: Sendable, Codable, Equatable, Identifiable {
    /// The id of the mail that carried it. A reply names this id.
    public let id: MailID

    /// The session or the user that sent the message.
    public let from: SessionMessageSender

    /// The session that the message went to.
    public let to: ULID

    /// The text of the message.
    public let text: String

    /// The id of the message that this message answers, or `nil` for a
    /// message that answers none.
    public let inReplyTo: MailID?

    /// The time the directory delivered the message.
    public let sentAt: Date

    /// 1 for a message from a turn that a user started, or from a UI.
    /// Plus 1 for each message in the chain. The limit is in ROUTER-5.
    public let chainDepth: Int

    /// True when the target read the message with
    /// ``SessionDirectory/inbox(of:markRead:)``.
    public var isRead: Bool

    /// Makes a delivered message.
    ///
    /// - Parameters:
    ///   - id: The id of the mail that carried the message.
    ///   - from: The session or the user that sent the message.
    ///   - to: The session that the message went to.
    ///   - text: The text of the message.
    ///   - inReplyTo: The id of the message that this message answers. The
    ///     default is `nil`.
    ///   - sentAt: The time the directory delivered the message.
    ///   - chainDepth: The depth of the message in its chain.
    ///   - isRead: True when the target read the message. The default is
    ///     `false`.
    public init(
        id: MailID,
        from: SessionMessageSender,
        to: ULID,
        text: String,
        inReplyTo: MailID? = nil,
        sentAt: Date,
        chainDepth: Int,
        isRead: Bool = false
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.text = text
        self.inReplyTo = inReplyTo
        self.sentAt = sentAt
        self.chainDepth = chainDepth
        self.isRead = isRead
    }
}
