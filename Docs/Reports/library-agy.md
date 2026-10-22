# SwitchShelf Library Implementation & NAS Validation Report

- **Worker**: agy (SwitchShelfLibrary)
- **Date**: 2026-10-22
- **Target Platform**: macOS 26+ (Apple Silicon), Swift 6 Concurrency
- **Module**: `Sources/SwitchShelfLibrary/**`, `Tests/SwitchShelfLibraryTests/**`
- **Acceptance Status**: Passed (`swift test --filter SwitchShelfLibraryTests` - 21 tests in 4 suites, 0 failures)

---

## 1. Implementation Scope

### 1.1 FilenameParser & Identity Candidate Extraction (`FilenameParser.swift`)
- **Supported Formats**: Read-only recognition of `.nsp`, `.xci`, `.nsz`, `.xcz`.
- **Filtering**:
  - Automatically skips AppleDouble resource fork files (`._*`) and hidden metadata (`.*`).
  - Automatically skips in-progress / temporary files (`.part`, `.tmp`, `.crdownload`, `.download`).
- **TitleID Candidate Recognition**:
  - Extracts 16-character hexadecimal TitleIDs from standard bracketed `[0100...]`, parenthesized `(0100...)`, or word-boundary patterns.
  - Normalizes IDs to uppercase.
  - Automatically derives base TitleIDs for updates (`...800` maps to base `...000`).
  - Strict guideline compliance: Filename TitleIDs are candidates and assigned `.matched`, never `.verified`.
- **Version Recognition**:
  - Raw integer versions parsed from `[v0]`, `[v65536]`, `[v131072]`, `[589824]`.
  - Display versions parsed from `[v1.0.1]`, `[版本1.0.1]`, `v1.4.0`.
- **Chinese Titles & Path Normalization**:
  - Extracts meaningful display names from Chinese folder names, filenames with spaces, and parent directory context.
  - Handles mixed Chinese and English titles (e.g. `未命名鹅游戏` with `originalTitle: Untitled Goose Game`, `潜水员戴夫` with `originalTitle: DAVE THE DIVER`).
  - Preserves unidentified files and homebrew applications without dropping entries.

### 1.2 LibraryScanner Actor (`LibraryScanner.swift`)
- Conforms to frozen public contract `LibraryScanning`:
  ```swift
  public actor LibraryScanner: LibraryScanning {
      public init()
      public func scan(_ source: LibrarySource) async throws -> LibrarySnapshot
  }
  ```
- **Security-Scoped Bookmarks**: Transparently resolves and accesses bookmarks with `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()`.
- **Directory Traversal**:
  - Asynchronous recursive enumeration via `FileManager.DirectoryEnumerator`.
  - Strictly ignores symbolic links (`isSymbolicLink == true`), avoiding recursive loops or external filesystem leaks.
  - Partial scan resilience: Directory permission errors or unreadable subfolders are captured in `snapshot.issues` without aborting the overall scan.
  - Fast, lightweight metadata collection using `fileSizeKey` and `contentModificationDateKey` without full hashes or large file reads.
- **Reliable Content Grouping**:
  - Groups base packages, updates, and DLCs sharing reliable TitleID relations or identical non-root game directories.
  - Adheres strictly to the rule: does not force arbitrary DLC arithmetic. Loose DLC in standalone folders remains as distinct game entries.

### 1.3 SQLite Database Layer (`SQLiteDatabase.swift`)
- Direct integration with system `CSQLite` library (`sqlite3.h`), zero third-party dependencies.
- **WAL Mode & Foreign Keys**: `PRAGMA journal_mode = WAL;` and `PRAGMA foreign_keys = ON;`.
- **Schema Migrations**: Monitored via `PRAGMA user_version`:
  - `sources`: `(id, url, name, availability, bookmark)`
  - `games`: `(id, title, original_title, cover_url, identification)`
  - `contents`: `(id, game_id, title_id, kind, raw_version, display_version, file_url, byte_count, format, availability)`
  - `snapshot_meta`: `(key, value)` (exact epoch timestamp for `scannedAt`)
  - `snapshot_issues`: `(id, issue)`
- **Transaction Safety**: `BEGIN IMMEDIATE TRANSACTION;`, `COMMIT;`, and automatic `ROLLBACK;` upon error.

### 1.4 LibraryRepository Actor (`LibraryRepository.swift`)
- Conforms to frozen public contract `LibraryPersisting`:
  ```swift
  public actor LibraryRepository: LibraryPersisting {
      public init(databaseURL: URL) throws
      public func load() async throws -> LibrarySnapshot
      public func save(_ snapshot: LibrarySnapshot) async throws
  }
  ```
- **Atomic Writes**: Whole-snapshot replacement within a single transaction ensures database state is never corrupted if write operations fail.
- **Offline Source Retention**:
  - If a source is unmounted or unreachable, contents belonging to that source are marked `.offline` and safely retained in SQLite.
  - Scanning or saving one source never wipes or drops records belonging to offline sources.

---

## 2. Real NAS Scan Evidence (`/Volumes/switch 游戏包`)

A bounded read-only scan was performed against the live SMB NAS mount at `/Volumes/switch 游戏包`.

### Summary Statistics
- **Target Volume**: `/Volumes/switch 游戏包` (SMB mounted NAS)
- **Scan Duration**: ~0.088 – 0.24 seconds
- **Total Games Identified**: 16 games
- **Total Packages Discovered**: 48 packages
- **Total Volume Size**: 92,313,880,284 bytes (92.31 GB)
- **Issues Encountered**: 0
- **I/O Safety**: 100% read-only metadata enumeration; zero file copying, zero full hashing, zero writes to the NAS mount.

### Discovered Inventory Samples
| Game Title | Candidate Base TitleID | Contents | State |
|---|---|---|---|
| 1-2-Switch | `01000320000CC000` | 1 Base, 1 Update | `matched` |
| 大家1-2-Switch | `01006F900BF8E000` | 1 Base, 1 Update | `matched` |
| 饥荒 | `0100751007ADA000` | 1 Base, 1 DLC | `matched` |
| 饥荒 联机版 | `010090100E334000` | 1 Base, 1 Update | `matched` |
| 蜡笔小新：煤炭镇的小白 | `010049901D704000` | 2 Base, 1 Update | `matched` |
| 路易吉鬼屋3 | `0100DCA0064A6000` | 1 Base, 1 Update, 2 DLC | `matched` |
| 脑锻炼 | `010062200D392000` | 1 Base | `matched` |
| 潜水员戴夫 | `010097F018538000` | 1 Base, 1 Update, 5 DLC | `matched` |
| 塞尔达传说 旷野之息 | `01007EF00011E000` | 1 Base, 3 Update, 2 DLC | `matched` |
| 双点医院 | `010031200E044000` | 1 Base, 1 Update, 5 DLC | `matched` |

---

## 3. Test Verification Suite (`SwitchShelfLibraryTests`)

Ran: `swift test --filter SwitchShelfLibraryTests`
Total: **21 tests across 4 suites, 0 failures**.

1. **`FilenameParserTests` (8 tests)**:
   - Standard Base Game parsing (`[01006F900BF8E000].xci`)
   - Update with base TitleID tag in filename (`[UPD][v1.0.1][01006F900BF8E000][v65536].nsp`)
   - Update with `800` TitleID calculating base TitleID (`Two Point Hospital [010031200E044800]`)
   - DLC with folder & tag extraction (`[DLC][0100DCA0064A7001]`)
   - Chinese titles and spaces (`塞尔达传说 旷野之息`)
   - Mixed Chinese/English dual title resolution
   - Homebrew and unidentified files without TitleID preserved
   - AppleDouble and temporary file ignore filters
2. **`LibraryScannerTests` (8 tests)**:
   - Recursive scanning through nested directory structures
   - Avoiding symlinks and symlink directory descent
   - Ignoring AppleDouble (`._*`) and temporary files (`.part`, `.tmp`)
   - Supporting Chinese filenames and spaces
   - Preserving unknown IDs as `.unidentified` (never `.verified`)
   - Reliable grouping of Base + Update + DLC without forcing DLC arithmetic
   - Partial scan failures capturing issues without aborting
   - Source unavailable throwing `LibraryScanError.sourceUnavailable`
3. **`LibraryRepositoryTests` (4 tests)**:
   - Schema migration initialization (version 1)
   - Snapshot roundtrip persistence (sources, bookmarks, games, contents, metadata, issues)
   - Offline source retention (offline sources preserved across saves and loads)
   - Atomic writes and rollback consistency
4. **`RealNASScanTests` (1 test)**:
   - Live read-only bounded scan of `/Volumes/switch 游戏包`

---

## 4. Limitations & Boundaries

1. **Candidate vs. Verified**: Filename identities, versions, and kinds are strictly candidates (`.matched` or `.unidentified`). Deep container verification against internal NCA headers and TitleDB is deferred to Wave 3.
2. **Compressed Packages (NSZ/XCZ)**: NSZ and XCZ files are indexed by container filename attributes; decompression or block checking is strictly omitted to avoid high I/O overhead over SMB.
3. **SMB Performance**: The scanner performs read-only directory enumeration; full file hashing was avoided to guarantee sub-second scan speeds over network shares.

---

## 5. Exact Commit
- **Branch**: `jiazi009/switchshelf-library`
- **Commit**: `7e887c2` (git rev-parse: `7e887c264ff6a9863eb39e432b577133a90c4f87`)


