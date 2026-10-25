import Foundation
import SwitchShelfDomain

public enum LibraryScanError: Error, LocalizedError, Equatable {
    case sourceUnavailable(URL)
    case accessDenied(URL)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .sourceUnavailable(let url):
            return "Library source directory is unavailable or does not exist: \(url.path)"
        case .accessDenied(let url):
            return "Permission denied accessing library source: \(url.path)"
        case .cancelled:
            return "Library scan was cancelled"
        }
    }
}

public actor LibraryScanner: LibraryScanning {
    public init() {}

    public func scan(_ source: LibrarySource) async throws -> LibrarySnapshot {
        var targetURL = source.url
        var didStartSecurityAccess = false

        if let bookmarkData = source.bookmark {
            var isStale = false
            // Background scans must not wait for a bookmark-resolution dialog.
            // The app refreshes access through explicit folder selection.
            if let resolved = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                targetURL = resolved
                didStartSecurityAccess = resolved.startAccessingSecurityScopedResource()
            }
        }

        defer {
            if didStartSecurityAccess {
                targetURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: targetURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw LibraryScanError.sourceUnavailable(targetURL)
        }

        var scanIssues: [String] = []
        let requestedKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey
        ]

        let enumerator = fileManager.enumerator(
            at: targetURL,
            includingPropertiesForKeys: Array(requestedKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                scanIssues.append("Error accessing \(url.path): \(error.localizedDescription)")
                return true // Continue scanning other items
            }
        )

        guard let enumerator else {
            throw LibraryScanError.sourceUnavailable(targetURL)
        }

        var parsedItems: [(content: LocalContent, parsed: ParsedPackage)] = []
        var coverCandidates: [String: [CoverCandidate]] = [:]

        while let fileURL = enumerator.nextObject() as? URL {
            try Task.checkCancellation()

            let resourceValues: URLResourceValues
            do {
                resourceValues = try fileURL.resourceValues(forKeys: requestedKeys)
            } catch {
                scanIssues.append("Failed to read attributes for \(fileURL.path): \(error.localizedDescription)")
                continue
            }

            // Strictly skip symbolic links without following them
            if resourceValues.isSymbolicLink == true {
                if resourceValues.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            if resourceValues.isDirectory == true {
                continue
            }

            let filename = fileURL.lastPathComponent
            if filename.hasPrefix(".") || filename.hasPrefix("._") {
                continue
            }

            // Sidecar artwork only. Package bytes are never opened to look for a cover.
            if LocalCoverLocator.isSidecarFilename(filename),
               resourceValues.isRegularFile == true,
               let directoryKey = FilenameParser.gameDirectoryKey(fileURL: fileURL, sourceRoot: targetURL) {
                let byteCount = Int64(resourceValues.fileSize ?? 0)
                if let relativeDirectory = FilenameParser.relativeDirectory(of: fileURL, sourceRoot: targetURL),
                   LocalCoverLocator.accepts(byteCount: byteCount) {
                    coverCandidates[directoryKey, default: []].append(
                        CoverCandidate(url: fileURL, byteCount: byteCount, relativeDirectory: relativeDirectory)
                    )
                }
                continue
            }

            guard let parsed = FilenameParser.parse(fileURL: fileURL, sourceRoot: targetURL) else {
                continue
            }

            let byteCount = Int64(resourceValues.fileSize ?? 0)
            let contentID = fileURL.path

            let content = LocalContent(
                id: contentID,
                titleID: parsed.titleID,
                kind: parsed.kind,
                rawVersion: parsed.rawVersion,
                displayVersion: parsed.displayVersion,
                fileURL: fileURL,
                byteCount: byteCount,
                format: parsed.format,
                availability: .online
            )

            parsedItems.append((content: content, parsed: parsed))
        }

        // Group into games
        let games = groupContentsIntoGames(items: parsedItems, sourceRoot: targetURL, covers: coverCandidates)

        var activeSource = source
        activeSource.availability = .online

        return LibrarySnapshot(
            sources: [activeSource],
            games: games,
            scannedAt: Date(),
            issues: scanIssues
        )
    }

    private func groupContentsIntoGames(
        items: [(content: LocalContent, parsed: ParsedPackage)],
        sourceRoot: URL,
        covers: [String: [CoverCandidate]]
    ) -> [Game] {
        struct GameBuilder {
            var title: String
            var originalTitle: String?
            var contents: [LocalContent]
            var primaryTitleID: String?
            var gameFolder: String
            var directoryKey: String
        }

        var builders: [String: GameBuilder] = [:] // Keyed by group key
        var baseTitleIDToKey: [String: String] = [:]
        var gameFolderToKeys: [String: Set<String>] = [:]

        func uniqueFolderKey(_ folder: String) -> String? {
            guard !folder.isEmpty, let keys = gameFolderToKeys[folder], keys.count == 1 else { return nil }
            return keys.first
        }

        func makeBuilder(_ item: (content: LocalContent, parsed: ParsedPackage), primaryTitleID: String?) -> GameBuilder {
            GameBuilder(
                title: item.parsed.gameTitle,
                originalTitle: item.parsed.originalTitle,
                contents: [item.content],
                primaryTitleID: primaryTitleID,
                gameFolder: item.parsed.gameFolder,
                directoryKey: FilenameParser.gameDirectoryKey(fileURL: item.content.fileURL, sourceRoot: sourceRoot) ?? ""
            )
        }

        // Pass 1: Register Base contents
        for item in items where item.parsed.kind == .base {
            let parsed = item.parsed
            let baseID = parsed.baseTitleID ?? parsed.titleID

            let key: String
            if let baseID {
                key = "titleid:\(baseID)"
            } else if !parsed.gameFolder.isEmpty {
                key = "folder:\(parsed.gameFolder)"
            } else {
                key = "title:\(parsed.gameTitle.lowercased())"
            }

            if builders[key] == nil {
                builders[key] = makeBuilder(item, primaryTitleID: baseID)
            } else {
                builders[key]?.contents.append(item.content)
            }

            if let baseID {
                baseTitleIDToKey[baseID] = key
            }
            if !parsed.gameFolder.isEmpty {
                gameFolderToKeys[parsed.gameFolder, default: []].insert(key)
            }
        }

        // Pass 2: Attach Updates
        for item in items where item.parsed.kind == .update {
            let parsed = item.parsed
            let targetKey: String?

            if let baseID = parsed.baseTitleID, let key = baseTitleIDToKey[baseID] {
                targetKey = key
            } else if let key = uniqueFolderKey(parsed.gameFolder) {
                targetKey = key
            } else {
                targetKey = nil
            }

            if let targetKey, builders[targetKey] != nil {
                builders[targetKey]?.contents.append(item.content)
            } else {
                // Standalone update
                let standaloneKey = "upd:\(item.content.id)"
                builders[standaloneKey] = makeBuilder(item, primaryTitleID: parsed.titleID)
            }
        }

        // Pass 3: Attach DLCs (only on reliable relation; do not force DLC arithmetic)
        for item in items where item.parsed.kind == .dlc {
            let parsed = item.parsed
            let targetKey: String?

            // A single base in the same game folder is a candidate relation;
            // matching a display title alone is never sufficient.
            if let key = uniqueFolderKey(parsed.gameFolder) {
                targetKey = key
            } else {
                targetKey = nil
            }

            if let targetKey, builders[targetKey] != nil {
                builders[targetKey]?.contents.append(item.content)
            } else {
                // Standalone DLC
                let standaloneKey = "dlc:\(item.content.id)"
                builders[standaloneKey] = makeBuilder(item, primaryTitleID: parsed.titleID)
            }
        }

        // Pass 4: Attach Unknown or remaining contents
        for item in items where item.parsed.kind == .unknown {
            let parsed = item.parsed
            let targetKey: String?

            if let key = uniqueFolderKey(parsed.gameFolder) {
                targetKey = key
            } else {
                targetKey = nil
            }

            if let targetKey, builders[targetKey] != nil {
                builders[targetKey]?.contents.append(item.content)
            } else {
                let standaloneKey = "unk:\(item.content.id)"
                builders[standaloneKey] = makeBuilder(item, primaryTitleID: parsed.titleID)
            }
        }

        // Convert builders to Game models
        var games: [Game] = []
        for (_, builder) in builders {
            let hasCandidateTitleID = builder.contents.contains { $0.titleID != nil } || builder.primaryTitleID != nil
            // Filename identities are candidates, never .verified!
            let identification: IdentificationState = hasCandidateTitleID ? .matched : .unidentified

            let gameID: String
            if let primaryID = builder.primaryTitleID {
                gameID = primaryID
            } else if !builder.contents.isEmpty {
                gameID = builder.contents[0].id
            } else {
                gameID = UUID().uuidString
            }

            let sortedContents = builder.contents.sorted { c1, c2 in
                if c1.kind != c2.kind {
                    return kindPriority(c1.kind) < kindPriority(c2.kind)
                }
                return (c1.rawVersion ?? 0) < (c2.rawVersion ?? 0)
            }

            let game = Game(
                id: gameID,
                title: builder.title.isEmpty ? "Unknown Game" : builder.title,
                originalTitle: builder.originalTitle,
                coverURL: LocalCoverLocator.select(covers[builder.directoryKey] ?? [], gameDirectory: builder.directoryKey),
                contents: sortedContents,
                identification: identification
            )
            games.append(game)
        }

        return games.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func kindPriority(_ kind: ContentKind) -> Int {
        switch kind {
        case .base: return 0
        case .update: return 1
        case .dlc: return 2
        case .unknown: return 3
        }
    }
}
