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

        // Keep games that do NOT belong to this source
        let sourcePath = source.url.standardizedFileURL.path
        var retainedGames: [Game] = []

        for game in self.games {
            let nonSourceContents = game.contents.filter { content in
                !content.fileURL.standardizedFileURL.path.hasPrefix(sourcePath)
            }
            if !nonSourceContents.isEmpty {
                var modifiedGame = game
                modifiedGame.contents = nonSourceContents
                retainedGames.append(modifiedGame)
            }
        }

        // Add newly scanned games for this source
        let combinedGames = (retainedGames + scanResult.games).sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }

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

        var updatedGames: [Game] = []
        for game in self.games {
            var modifiedContents: [LocalContent] = []
            for content in game.contents {
                var modifiedContent = content
                if let targetPath = targetSourcePath,
                   content.fileURL.standardizedFileURL.path.hasPrefix(targetPath) {
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
