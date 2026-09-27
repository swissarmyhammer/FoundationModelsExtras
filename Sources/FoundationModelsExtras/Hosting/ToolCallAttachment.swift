/// A structured record that a tool attaches to its call, for example a set
/// of file changes.
///
/// The host session does not read the record. It carries `contentJSON` as
/// an opaque JSON document, and `schemaName` as the name of its type, so
/// that a host can decode it. The model never sees an attachment.
public struct ToolCallAttachment: Sendable, Equatable, Codable {
    /// The name of the type that `contentJSON` encodes.
    public let schemaName: String

    /// The JSON document that the tool owns.
    public let contentJSON: String

    /// Makes an attachment.
    ///
    /// - Parameters:
    ///   - schemaName: The name of the type that `contentJSON` encodes.
    ///   - contentJSON: The JSON document that the tool owns.
    public init(schemaName: String, contentJSON: String) {
        self.schemaName = schemaName
        self.contentJSON = contentJSON
    }
}
