extension String {
    /// The Levenshtein distance between two texts: the least number of one-character inserts, deletes and changes
    /// from one to the other.
    ///
    /// - Parameter target: The other text.
    /// - Returns: The edit distance.
    func editDistance(to target: String) -> Int {
        let targetCharacters = Array(target)
        var previousRow = Array(0...targetCharacters.count)
        for (sourceIndex, sourceCharacter) in enumerated() {
            var currentRow = [sourceIndex + 1]
            for (targetIndex, targetCharacter) in targetCharacters.enumerated() {
                let change = previousRow[targetIndex] + (sourceCharacter == targetCharacter ? 0 : 1)
                currentRow.append(Swift.min(change, previousRow[targetIndex + 1] + 1, currentRow[targetIndex] + 1))
            }
            previousRow = currentRow
        }
        return previousRow[targetCharacters.count]
    }
}
