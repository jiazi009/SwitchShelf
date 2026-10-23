import Foundation
import SwitchShelfDomain

struct ObjectIdentity: Equatable, Sendable {
    var titleID: String?
    var rawVersion: UInt32?
    var kind: ContentKind
    var issues: [String]
}

/// Only explicit, delimited machine tokens in the object filename are evidence.
/// Never use the human title, parent folder's identity, display version or ID arithmetic.
enum InstalledObjectParser {
    static func parse(_ name: String) -> ObjectIdentity {
        let tokens = matches(#"\[([^\[\]]+)\]"#, in: name).map { $0.lowercased() }
        var ids = Set<String>(), versions = Set<UInt32>(), kinds = Set<ContentKind>()
        var issues: [String] = []
        for token in tokens {
            let id = token.hasPrefix("titleid=") ? String(token.dropFirst(8)) : token
            if id.range(of: #"^01[0-9a-f]{14}$"#, options: .regularExpression) != nil {
                ids.insert(id.uppercased())
            } else if token.hasPrefix("titleid=") {
                issues.append("Invalid explicit TitleID token.")
            }
            let raw: String?
            if token.hasPrefix("version=") { raw = String(token.dropFirst(8)) }
            else if token.hasPrefix("v"), token.dropFirst().allSatisfy(\.isASCII),
                    token.dropFirst().allSatisfy(\.isNumber), token.count > 1 { raw = String(token.dropFirst()) }
            else { raw = nil }
            if let raw {
                let value: UInt32?
                if raw.hasPrefix("0x") { value = UInt32(raw.dropFirst(2), radix: 16) }
                else if raw.allSatisfy({ $0.isASCII && $0.isNumber }), !raw.isEmpty { value = UInt32(raw) }
                else { value = nil }
                if let value { versions.insert(value) }
                else { issues.append("Invalid or overflowing explicit raw-version token.") }
            }
            switch token {
            case "base", "application": kinds.insert(.base)
            case "upd", "update", "patch": kinds.insert(.update)
            case "dlc", "addoncontent": kinds.insert(.dlc)
            default: break
            }
        }
        if ids.count != 1 { issues.append(ids.isEmpty ? "No explicit TitleID token." : "Multiple TitleIDs: combined or ambiguous object.") }
        if versions.count != 1 { issues.append(versions.isEmpty ? "No explicit raw-version token." : "Conflicting raw-version tokens.") }
        if kinds.count != 1 { issues.append(kinds.isEmpty ? "No explicit content-kind token; kind remains unknown." : "Multiple content kinds: combined or ambiguous object.") }
        return ObjectIdentity(titleID: ids.count == 1 && !issues.contains("Invalid explicit TitleID token.") ? ids.first : nil,
                              rawVersion: versions.count == 1 && !issues.contains(where: { $0.hasPrefix("Invalid") }) ? versions.first : nil,
                              kind: kinds.count == 1 ? kinds.first! : .unknown, issues: issues)
    }
    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}

struct InventoryReader: Sendable {
    var maximumObjects = 100_000
    var maximumDepth = 64
    var budget: Duration = .seconds(45)
    static let root = UInt32.max

    static func isInstalledGames(_ name: String) -> Bool {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "installed games" || value == "4: installed games"
    }

    private static func storageDiagnostic(_ storages: [MTPStorage]) -> String {
        // These are descriptions already returned by GetStorageInfo, not volume
        // labels or device identifiers. Bound and escape diagnostic text without
        // treating an unfamiliar name as installed-content evidence.
        let entries = storages.prefix(16).map { storage in
            let name = String(String.UnicodeScalarView(storage.name.unicodeScalars.prefix(128)))
            let truncated = storage.name.unicodeScalars.count > 128 ? "（名称已截断）" : ""
            return "\(storage.id): \(name.debugDescription)\(truncated)"
        }
        let omitted = storages.count > 16 ? "；其余 \(storages.count - 16) 项省略" : ""
        return "设备报告的 MTP 存储（\(storages.count) 项，ID 仅属于本次会话）：\(entries.joined(separator: "；"))\(omitted)"
    }

    func read(from transport: any InventoryTransport, storageDiagnosticsOnly: Bool = false) async throws -> InstalledInventory {
        try Task.checkCancellation()
        let sessionID = "mtp-session-\(UUID().uuidString)"
        let started = ContinuousClock.now
        let storages = try await transport.storages()
        try Task.checkCancellation()
        var inventory = InstalledInventory(deviceID: sessionID, environmentContext: nil, isComplete: false)
        if storageDiagnosticsOnly {
            inventory.issues = [
                "本次仅枚举 MTP 存储名称，未遍历任何内容对象，不构成已安装清单。",
                Self.storageDiagnostic(storages)
            ]
            return inventory
        }
        let targets = storages.filter { Self.isInstalledGames($0.name) }
        guard !targets.isEmpty else {
            inventory.issues = [
                "未识别出 DBI 的 Installed games 存储；入口未暴露或名称不匹配均有可能，请核对入口开关与下列实际存储名称。当前结果不代表设备没有已安装游戏。",
                Self.storageDiagnostic(storages)
            ]
            return inventory
        }
        var complete = true
        func issue(_ text: String) {
            complete = false
            // Bound diagnostics even for a pathological tree. Keep a terminal suppression marker.
            if inventory.issues.count < 199 { inventory.issues.append(text) }
            else if inventory.issues.count == 199 { inventory.issues.append("Further inventory issues suppressed; inventory remains incomplete.") }
        }
        var seenStorages = Set<UInt32>(), seenObjects = Set<UInt32>(), identities = Set<String>()
        var contentFolders = Set<UInt32>(), candidateFolders = Set<UInt32>()
        var folderParents: [UInt32: UInt32] = [:]
        var topLevelFolderIDs: [UInt32: String] = [:]
        var nestedBaseIDs: [UInt32: Set<String>] = [:]
        var rootProjections: [(id: UInt32, titleID: String?)] = []
        var objectCount = 0
        var stop = false
        for storage in targets {
            guard storage.id != 0, seenStorages.insert(storage.id).inserted else {
                issue("Installed games storage identity is invalid or duplicated."); continue
            }
            var pending: [(parent: UInt32, path: String, depth: Int)] = [(Self.root, storage.name, 0)]
            while let folder = pending.popLast(), !stop {
                if Task.isCancelled { throw CancellationError() }
                if ContinuousClock.now - started > budget {
                    issue("Inventory traversal exceeded its time budget; coverage is incomplete."); stop = true; break
                }
                let children: [UInt32]
                do {
                    children = try await transport.children(storage: storage.id, parent: folder.parent)
                    try Task.checkCancellation()
                } catch is CancellationError { throw CancellationError() }
                catch {
                    issue("Cannot enumerate folder \(storage.id):\(folder.parent) (\(safeError(error))); coverage is incomplete.")
                    continue
                }
                if children.isEmpty && folder.depth > 0 {
                    issue("An Installed games subfolder has no content objects; its identity/coverage cannot be verified.")
                }
                for id in children {
                    if Task.isCancelled { throw CancellationError() }
                    if objectCount >= maximumObjects || ContinuousClock.now - started > budget {
                        issue("Inventory traversal reached its object/time safety limit; coverage is incomplete."); stop = true; break
                    }
                    objectCount += 1
                    guard id != 0, id != Self.root, seenObjects.insert(id).inserted else {
                        issue("Duplicate, cyclic or invalid MTP object handle \(id)."); continue
                    }
                    let object: MTPObject
                    do {
                        object = try await transport.object(id: id)
                        try Task.checkCancellation()
                    } catch is CancellationError { throw CancellationError() }
                    catch { issue("Cannot read object metadata \(id) (\(safeError(error))); coverage is incomplete."); continue }
                    let parentMatches = object.parentID == folder.parent ||
                        (folder.parent == Self.root && object.parentID == 0)
                    guard object.id == id, object.storageID == storage.id, parentMatches,
                          !object.name.isEmpty, !object.name.contains("/"), !object.name.contains("\0"),
                          object.name != ".", object.name != ".." else {
                        issue("Object \(id) has inconsistent location or invalid name metadata."); continue
                    }
                    let path = folder.path + "/" + object.name
                    if object.isFolder {
                        // Official DBI docs: this is a redirection to SD mods/cheats, NOT installed content.
                        if object.name.caseInsensitiveCompare("Mods & Cheats") == .orderedSame { continue }
                        guard folder.depth < maximumDepth else {
                            issue("Installed games traversal reached its depth safety limit."); continue
                        }
                        candidateFolders.insert(id)
                        folderParents[id] = folder.parent
                        if folder.depth == 0, let titleID = InstalledObjectParser.parse(object.name).titleID {
                            topLevelFolderIDs[id] = titleID
                        }
                        pending.append((id, path, folder.depth + 1))
                    } else {
                        let ext = (object.name as NSString).pathExtension.lowercased()
                        guard ["nsp", "nsz", "xci", "xcz"].contains(ext) else {
                            issue("Non-package object \(id) cannot establish installed-content identity."); continue
                        }
                        if folder.depth == 0 {
                            // Resolve only after the corresponding nested game is fully traversed.
                            // Aggregates never become individual content records.
                            rootProjections.append((id, InstalledObjectParser.parse(object.name).titleID))
                            continue
                        }
                        let parsed = InstalledObjectParser.parse(object.name)
                        for detail in parsed.issues { issue("Object \(id): \(detail)") }
                        if parsed.issues.isEmpty, let titleID = parsed.titleID, let version = parsed.rawVersion {
                            var ancestor = folder.parent
                            while ancestor != Self.root {
                                contentFolders.insert(ancestor)
                                if parsed.kind == .base { nestedBaseIDs[ancestor, default: []].insert(titleID) }
                                ancestor = folderParents[ancestor] ?? Self.root
                            }
                            let key = "\(titleID):\(parsed.kind.rawValue):\(version)"
                            guard identities.insert(key).inserted else { continue }
                        }
                        inventory.records.append(InstalledRecord(id: "\(sessionID):\(storage.id):\(id)",
                            titleID: parsed.titleID, kind: parsed.kind, rawVersion: parsed.rawVersion,
                            name: object.name, objectPath: path))
                    }
                }
            }
            if stop { break }
        }
        if !candidateFolders.subtracting(contentFolders).isEmpty {
            issue("One or more Installed games folders lack an attributable content object; this cannot establish an empty/complete content inventory.")
        }
        let traversalComplete = complete
        for projection in rootProjections {
            let matches = topLevelFolderIDs.filter { folder, titleID in
                titleID == projection.titleID && nestedBaseIDs[folder]?.contains(titleID) == true
            }
            // DBI's documented aggregate projection plus three explicit identity observations:
            // root filename ID == unique game-folder ID == nested BASE content ID.
            // Never associate by a human display title or assume root ID identifies one content.
            if !traversalComplete || projection.titleID == nil || matches.count != 1 {
                issue("Root virtual package \(projection.id) is an unattributed combined projection, omitted from content records; per-content coverage is not verified.")
            }
        }
        try Task.checkCancellation()
        inventory.isComplete = complete
        inventory.observedAt = Date()
        inventory.records.sort { $0.objectPath < $1.objectPath }
        return inventory
    }
    private func safeError(_ error: any Error) -> String {
        // Never propagate arbitrary device/native messages: they can contain serials/paths.
        if let error = error as? DeviceServiceError { return error.code.rawValue }
        return "transport failure"
    }
}
