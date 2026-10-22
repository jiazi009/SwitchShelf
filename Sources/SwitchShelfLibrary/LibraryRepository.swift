import Foundation
import SwitchShelfDomain

public actor LibraryRepository: LibraryPersisting {
    private let db: SQLiteDatabase

    public init(databaseURL: URL) throws {
        self.db = try SQLiteDatabase(databaseURL: databaseURL)
    }

    public func load() async throws -> LibrarySnapshot {
        // 1. Load Sources
        let sourceStmt = try db.prepare(
            "SELECT id, url, name, availability, bookmark FROM sources ORDER BY name ASC;"
        )
        defer { sourceStmt.finalize() }

        var sources: [LibrarySource] = []
        while try sourceStmt.step() {
            guard let id = sourceStmt.columnText(0),
                  let urlString = sourceStmt.columnText(1),
                  let url = URL(string: urlString),
                  let name = sourceStmt.columnText(2),
                  let availString = sourceStmt.columnText(3) else {
                continue
            }
            let availability = SourceAvailability(rawValue: availString) ?? .unknown
            let bookmark = sourceStmt.columnBlob(4)
            sources.append(LibrarySource(
                id: id,
                url: url,
                name: name,
                availability: availability,
                bookmark: bookmark
            ))
        }

        // 2. Load Contents grouped by game_id
        let contentStmt = try db.prepare("""
            SELECT id, game_id, title_id, kind, raw_version, display_version, file_url, byte_count, format, availability
            FROM contents
            ORDER BY rowid ASC;
        """)
        defer { contentStmt.finalize() }

        var contentsByGameID: [String: [LocalContent]] = [:]
        while try contentStmt.step() {
            guard let id = contentStmt.columnText(0),
                  let gameID = contentStmt.columnText(1),
                  let kindString = contentStmt.columnText(3),
                  let kind = ContentKind(rawValue: kindString),
                  let fileURLString = contentStmt.columnText(6),
                  let fileURL = URL(string: fileURLString),
                  let byteCount = contentStmt.columnInt64(7),
                  let formatString = contentStmt.columnText(8),
                  let format = PackageFormat(rawValue: formatString),
                  let availString = contentStmt.columnText(9) else {
                continue
            }

            let titleID = contentStmt.columnText(2)
            let rawVersion = contentStmt.columnInt64(4).flatMap { UInt32(exactly: $0) }
            let displayVersion = contentStmt.columnText(5)
            let availability = SourceAvailability(rawValue: availString) ?? .online

            let content = LocalContent(
                id: id,
                titleID: titleID,
                kind: kind,
                rawVersion: rawVersion,
                displayVersion: displayVersion,
                fileURL: fileURL,
                byteCount: byteCount,
                format: format,
                availability: availability
            )
            contentsByGameID[gameID, default: []].append(content)
        }

        // 3. Load Games
        let gameStmt = try db.prepare("""
            SELECT id, title, original_title, cover_url, identification
            FROM games
            ORDER BY title ASC;
        """)
        defer { gameStmt.finalize() }

        var games: [Game] = []
        while try gameStmt.step() {
            guard let id = gameStmt.columnText(0),
                  let title = gameStmt.columnText(1),
                  let identString = gameStmt.columnText(4) else {
                continue
            }
            let originalTitle = gameStmt.columnText(2)
            let coverURL = gameStmt.columnText(3).flatMap { URL(string: $0) }
            let identification = IdentificationState(rawValue: identString) ?? .needsReview
            let contents = contentsByGameID[id] ?? []

            games.append(Game(
                id: id,
                title: title,
                originalTitle: originalTitle,
                coverURL: coverURL,
                contents: contents,
                identification: identification
            ))
        }

        // 4. Load ScannedAt Metadata
        var scannedAt: Date? = nil
        let metaStmt = try db.prepare("SELECT value FROM snapshot_meta WHERE key = 'scannedAt';")
        defer { metaStmt.finalize() }
        if try metaStmt.step(), let timestampStr = metaStmt.columnText(0), let seconds = Double(timestampStr) {
            scannedAt = Date(timeIntervalSince1970: seconds)
        }

        // 5. Load Issues
        var issues: [String] = []
        let issueStmt = try db.prepare("SELECT issue FROM snapshot_issues ORDER BY id ASC;")
        defer { issueStmt.finalize() }
        while try issueStmt.step() {
            if let issue = issueStmt.columnText(0) {
                issues.append(issue)
            }
        }

        return LibrarySnapshot(
            sources: sources,
            games: games,
            scannedAt: scannedAt,
            issues: issues
        )
    }

    public func save(_ snapshot: LibrarySnapshot) async throws {
        try db.beginTransaction()
        do {
            try db.execute("DELETE FROM contents;")
            try db.execute("DELETE FROM games;")
            try db.execute("DELETE FROM sources;")
            try db.execute("DELETE FROM snapshot_meta;")
            try db.execute("DELETE FROM snapshot_issues;")

            // Insert sources
            let sourceStmt = try db.prepare("""
                INSERT INTO sources (id, url, name, availability, bookmark)
                VALUES (?, ?, ?, ?, ?);
            """)
            defer { sourceStmt.finalize() }

            for source in snapshot.sources {
                sourceStmt.reset()
                try sourceStmt.bindText(1, source.id)
                try sourceStmt.bindText(2, source.url.absoluteString)
                try sourceStmt.bindText(3, source.name)
                try sourceStmt.bindText(4, source.availability.rawValue)
                try sourceStmt.bindBlob(5, source.bookmark)
                _ = try sourceStmt.step()
            }

            // Insert games and contents
            let gameStmt = try db.prepare("""
                INSERT INTO games (id, title, original_title, cover_url, identification)
                VALUES (?, ?, ?, ?, ?);
            """)
            defer { gameStmt.finalize() }

            let contentStmt = try db.prepare("""
                INSERT INTO contents (id, game_id, title_id, kind, raw_version, display_version, file_url, byte_count, format, availability)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
            defer { contentStmt.finalize() }

            for game in snapshot.games {
                gameStmt.reset()
                try gameStmt.bindText(1, game.id)
                try gameStmt.bindText(2, game.title)
                try gameStmt.bindText(3, game.originalTitle)
                try gameStmt.bindText(4, game.coverURL?.absoluteString)
                try gameStmt.bindText(5, game.identification.rawValue)
                _ = try gameStmt.step()

                for content in game.contents {
                    contentStmt.reset()
                    try contentStmt.bindText(1, content.id)
                    try contentStmt.bindText(2, game.id)
                    try contentStmt.bindText(3, content.titleID)
                    try contentStmt.bindText(4, content.kind.rawValue)
                    try contentStmt.bindInt64(5, content.rawVersion.map { Int64($0) })
                    try contentStmt.bindText(6, content.displayVersion)
                    try contentStmt.bindText(7, content.fileURL.absoluteString)
                    try contentStmt.bindInt64(8, content.byteCount)
                    try contentStmt.bindText(9, content.format.rawValue)
                    try contentStmt.bindText(10, content.availability.rawValue)
                    _ = try contentStmt.step()
                }
            }

            // Insert scannedAt metadata
            if let scannedAt = snapshot.scannedAt {
                let metaStmt = try db.prepare("INSERT INTO snapshot_meta (key, value) VALUES (?, ?);")
                defer { metaStmt.finalize() }
                try metaStmt.bindText(1, "scannedAt")
                try metaStmt.bindText(2, String(scannedAt.timeIntervalSince1970))
                _ = try metaStmt.step()
            }

            // Insert issues
            let issueStmt = try db.prepare("INSERT INTO snapshot_issues (issue) VALUES (?);")
            defer { issueStmt.finalize() }
            for issue in snapshot.issues {
                issueStmt.reset()
                try issueStmt.bindText(1, issue)
                _ = try issueStmt.step()
            }

            try db.commit()
        } catch {
            try? db.rollback()
            throw error
        }
    }
}
