import Foundation

/// Where an imported session came from: the agent that recorded it, its id,
/// its file and its title in the store of that agent, and the times of its
/// last record and of the import.
public struct SessionImportProvenance: Sendable, Codable, Equatable {
    /// The agent that recorded the source session, for example `claude-code`
    /// or `codex`.
    public var agent: String

    /// The id of the source session in the store of that agent.
    public var sourceID: String

    /// The path of the file of the source session.
    public var sourcePath: String

    /// The title that the source reader found for the source session, for
    /// example from a summary record or from the first user prompt. It is
    /// `nil` when the reader found no title.
    public var sourceTitle: String?

    /// The time of the last record of the source session, or `nil` when the
    /// source gives no time.
    public var sourceLastDate: Date?

    /// The time of the import.
    public var importedAt: Date

    /// The number of records of the source that the import did not read.
    public var skippedRecordCount: Int

    /// Makes a provenance.
    ///
    /// - Parameters:
    ///   - agent: The agent that recorded the source session.
    ///   - sourceID: The id of the source session.
    ///   - sourcePath: The path of the file of the source session.
    ///   - sourceTitle: The title that the source reader found. The default
    ///     is `nil`.
    ///   - sourceLastDate: The time of the last record. The default is `nil`.
    ///   - importedAt: The time of the import.
    ///   - skippedRecordCount: The number of records that the import did not
    ///     read. The default is 0.
    public init(
        agent: String,
        sourceID: String,
        sourcePath: String,
        sourceTitle: String? = nil,
        sourceLastDate: Date? = nil,
        importedAt: Date,
        skippedRecordCount: Int = 0
    ) {
        self.agent = agent
        self.sourceID = sourceID
        self.sourcePath = sourcePath
        self.sourceTitle = sourceTitle
        self.sourceLastDate = sourceLastDate
        self.importedAt = importedAt
        self.skippedRecordCount = skippedRecordCount
    }
}
