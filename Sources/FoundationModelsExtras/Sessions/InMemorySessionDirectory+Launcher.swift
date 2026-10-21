import Foundation

extension InMemorySessionDirectory {
    /// The fake launcher of the test double: the agent ids that it knows,
    /// and the folder that a start with no folder and no starter gets.
    ///
    /// It resolves a start as session.md section 6 says, with no disk and no
    /// agent catalog: a nil agent id is the default agent, and a nil folder
    /// is the folder of `startedBy`, else ``defaultWorkingDirectory``.
    public struct Launcher: Sendable, Equatable {
        /// The id of the default agent, the root `Agents/AGENT.md` (D61). The
        /// launcher always knows it.
        public static let defaultAgentID = "default"

        /// The largest edit distance from an unknown id to a known id that
        /// makes the known id a near name.
        static let nearNameDistance = 2

        /// The agent ids that the launcher knows, ``defaultAgentID`` too.
        public let agentIDs: Set<String>

        /// The folder that a start with no folder and no starter gets: the
        /// root agent folder.
        public let defaultWorkingDirectory: URL

        /// Makes a fake launcher.
        ///
        /// - Parameters:
        ///   - agentIDs: The agent ids that the launcher knows. It knows
        ///     ``defaultAgentID`` as well.
        ///   - defaultWorkingDirectory: The folder that a start with no folder
        ///     and no starter gets.
        public init(agentIDs: [String], defaultWorkingDirectory: URL) {
            self.agentIDs = Set(agentIDs).union([Self.defaultAgentID])
            self.defaultWorkingDirectory = defaultWorkingDirectory
        }

        /// Resolves the agent id of a start.
        ///
        /// - Parameter requested: The agent id of the request, or `nil` for
        ///   the default agent.
        /// - Returns: The agent id of the new session.
        /// - Throws: ``SessionDirectoryError/unknownAgent(_:nearNames:)`` when
        ///   the launcher does not know the id.
        func resolveAgent(_ requested: String?) throws -> String {
            let agentID = requested ?? Self.defaultAgentID
            guard agentIDs.contains(agentID) else {
                throw SessionDirectoryError.unknownAgent(agentID, nearNames: nearNames(to: agentID))
            }
            return agentID
        }

        /// The known ids near `unknownID`, the nearest first, then in name
        /// order.
        ///
        /// - Parameter unknownID: An agent id that the launcher does not know.
        /// - Returns: The known ids at most ``nearNameDistance`` edits away.
        private func nearNames(to unknownID: String) -> [String] {
            agentIDs
                .map { (id: $0, distance: Self.editDistance(from: unknownID.lowercased(), to: $0.lowercased())) }
                .filter { $0.distance <= Self.nearNameDistance }
                .sorted { ($0.distance, $0.id) < ($1.distance, $1.id) }
                .map(\.id)
        }

        /// The Levenshtein distance between two texts: the least number of
        /// one-character inserts, deletes and changes from one to the other.
        ///
        /// - Parameters:
        ///   - source: The first text.
        ///   - target: The second text.
        /// - Returns: The edit distance.
        private static func editDistance(from source: String, to target: String) -> Int {
            let targetCharacters = Array(target)
            var previousRow = Array(0...targetCharacters.count)
            for (sourceIndex, sourceCharacter) in source.enumerated() {
                var currentRow = [sourceIndex + 1]
                for (targetIndex, targetCharacter) in targetCharacters.enumerated() {
                    let change = previousRow[targetIndex] + (sourceCharacter == targetCharacter ? 0 : 1)
                    currentRow.append(min(change, previousRow[targetIndex + 1] + 1, currentRow[targetIndex] + 1))
                }
                previousRow = currentRow
            }
            return previousRow[targetCharacters.count]
        }
    }
}
