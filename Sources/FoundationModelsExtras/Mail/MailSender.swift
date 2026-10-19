import ULID

/// The party that sent one ``Mail``.
public enum MailSender: Sendable, Codable, Hashable {
    /// The user of the session.
    case user

    /// A tool run. The value is ``OperationEvent/correlationID`` of the run,
    /// that is, the completion token of the tool call that started it.
    case run(correlationID: String)

    /// The answer to an elicitation. The value is the id of the elicitation.
    case elicitation(ULID)

    /// An other session, for example a parent agent. The value is the
    /// session id of the sender.
    case session(ULID)

    /// The tool package of a catalog, for a ``MailBody/catalogChange(_:)``.
    /// The value is the kind of the catalog.
    case catalog(CatalogKind)
}
