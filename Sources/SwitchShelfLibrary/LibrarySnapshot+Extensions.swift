import Foundation
import SwitchShelfDomain

extension LibrarySnapshot {
    /// Merges a newly scanned snapshot for a specific source into this snapshot,
    /// preserving other sources and their contents untouched.
    public func merging(scanResult: LibrarySnapshot, for source: LibrarySource) -> LibrarySnapshot {
        var updatedSources = self.sources.filter { $0.id != source.id }
        if let scannedSource = scanResult.sources.first(where: { $0.id == source.id }) {
            updatedSources.append(scannedSource)
        } else {
            updatedSources.append(source)
        }

        // Only a path component boundary denotes membership. /Games must not match /Games2.
        let sourcePath = source.url.standardizedFileURL.path
        func belongsToSource(_ url: URL) -> Bool {
            let path = url.standardizedFileURL.path
            return path == sourcePath || path.hasPrefix(sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/")
        }
        var retainedGames: [Game] = []

        for game in self.games {
            let nonSourceContents = game.contents.filter { content in
                !belongsToSource(content.fileURL)
            }
            if !nonSourceContents.isEmpty {
                var modifiedGame = game
                modifiedGame.contents = nonSourceContents
                retainedGames.append(modifiedGame)
            }
        }

        // A game can span multiple sources. Keep its stable ID and merge its content
        // rather than producing duplicate game rows (invalid for the SQLite key).
        var combinedGames = retainedGames
        var indexes = Dictionary(uniqueKeysWithValues: combinedGames.enumerated().map { ($0.element.id, $0.offset) })
        for scanned in scanResult.games {
            if let index = indexes[scanned.id] {
                let existingIDs = Set(combinedGames[index].contents.map(\.id))
                combinedGames[index].contents.append(contentsOf: scanned.contents.filter { !existingIDs.contains($0.id) })
            } else {
                indexes[scanned.id] = combinedGames.count
                combinedGames.append(scanned)
            }
        }
        combinedGames.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        var combinedIssues = self.issues
        for issue in scanResult.issues where !combinedIssues.contains(issue) {
            combinedIssues.append(issue)
        }

        return LibrarySnapshot(
            sources: updatedSources.sorted { $0.name < $1.name },
            games: combinedGames,
            scannedAt: scanResult.scannedAt ?? Date(),
            issues: combinedIssues
        )
    }

    /// Marks a specific source and all its associated game contents as offline without wiping them.
    public func markingSourceOffline(sourceID: String, reason: String? = nil) -> LibrarySnapshot {
        var updatedSources = self.sources
        var targetSourcePath: String? = nil

        for i in 0..<updatedSources.count {
            if updatedSources[i].id == sourceID {
                updatedSources[i].availability = .offline
                targetSourcePath = updatedSources[i].url.standardizedFileURL.path
            }
        }

        func belongsToSource(_ url: URL, root: String) -> Bool {
            let path = url.standardizedFileURL.path
            return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
        var updatedGames: [Game] = []
        for game in self.games {
            var modifiedContents: [LocalContent] = []
            for content in game.contents {
                var modifiedContent = content
                if let targetPath = targetSourcePath,
                   belongsToSource(content.fileURL, root: targetPath) {
                    modifiedContent.availability = .offline
                }
                modifiedContents.append(modifiedContent)
            }
            var modifiedGame = game
            modifiedGame.contents = modifiedContents
            updatedGames.append(modifiedGame)
        }

        var updatedIssues = self.issues
        if let reason, !updatedIssues.contains(reason) {
            updatedIssues.append(reason)
        }

        return LibrarySnapshot(
            sources: updatedSources,
            games: updatedGames,
            scannedAt: self.scannedAt,
            issues: updatedIssues
        )
    }
}
