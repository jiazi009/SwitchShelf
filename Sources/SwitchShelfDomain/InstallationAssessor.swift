import Foundation

/// Assesses device evidence separately from local transfer history.
/// Filename `.matched` games may be compared with the current inventory by explicit
/// Title ID and content kind. That comparison never promotes identification to
/// `.verified` and never claims the package bytes were checked.
public enum InstallationAssessor {
    public static func assess(_ game: Game, inventory: InstalledInventory?, isCurrentSession: Bool) -> InstallationAssessment {
        guard let inventory else { return result(.unknown, "尚未读取目标设备的已安装清单") }
        guard isCurrentSession else { return result(.unknown, "仅有上次读取记录，请重新连接并刷新", inventory) }
        switch game.identification {
        case .verified:
            return assessVerified(game, inventory)
        case .matched:
            return assessFilename(game, inventory)
        case .needsReview, .unidentified:
            return result(.unknown, "本地包身份尚未验证；文件名中的 Title ID 仅是候选，不能据此判断安装状态", inventory)
        }
    }

    /// One local file, using the same Title ID and content-kind evidence as `assess(_:)`.
    /// A check mark is only for `.installed`, so a partial game leaves the missing item unchecked.
    public static func assess(
        _ content: LocalContent,
        in game: Game,
        inventory: InstalledInventory?,
        isCurrentSession: Bool
    ) -> InstallationAssessment {
        let filenameIdentity = game.identification == .matched
        guard filenameIdentity || game.identification == .verified else {
            return assess(game, inventory: inventory, isCurrentSession: isCurrentSession)
        }
        guard let inventory else {
            return result(.unknown, filenameIdentity
                ? filenameNote("尚未读取当前设备清单。")
                : "尚未读取目标设备的已安装清单")
        }
        guard isCurrentSession else {
            return result(.unknown, filenameIdentity
                ? filenameNote("仅有上次读取记录，不能当作当前已安装。")
                : "仅有上次读取记录，请重新连接并刷新", inventory)
        }
        guard let id = normalizedID(content.titleID), content.kind != .unknown else {
            return result(.unknown, filenameIdentity
                ? filenameNote("这项内容没有可核对的 Title ID 或内容类型。")
                : "本地缺少可核对的 Title ID 或内容类型，不推断单项状态。", inventory)
        }
        let known = inventory.records.filter { normalizedID($0.titleID) != nil }
        let matches = known.filter { normalizedID($0.titleID) == id && $0.kind == content.kind }
        let allDeviceIdentitiesKnown = inventory.records.allSatisfy { normalizedID($0.titleID) != nil && $0.kind != .unknown }
        let absenceIsEvidence = inventory.isComplete && allDeviceIdentitiesKnown
        if matches.isEmpty {
            if absenceIsEvidence {
                return result(.notInstalled, note(filenameIdentity, "完整且身份齐全的清单中没有此 Title ID 与内容类型。"), inventory)
            }
            return result(.unknown, note(filenameIdentity, "清单或身份不完整，无法确认此项是否安装。"), inventory)
        }
        let comparesVersion = content.kind == .update || (filenameIdentity && content.kind == .dlc)
        if comparesVersion {
            let siblings = game.contents.filter { normalizedID($0.titleID) == id && $0.kind == content.kind }
            let deviceVersions = matches.compactMap(\.rawVersion)
            if content.rawVersion == nil || siblings.contains(where: { $0.rawVersion == nil }) || deviceVersions.isEmpty {
                return result(.unknown, note(filenameIdentity, "版本无法对照，不把此项勾为已安装。"), inventory)
            }
            if let local = content.rawVersion, let actual = deviceVersions.max(), actual < local {
                return result(.notInstalled, note(filenameIdentity, "设备上的版本低于本地这项内容。"), inventory)
            }
        }
        return result(.installed, note(filenameIdentity, "Title ID 与内容类型一致。"), inventory)
    }

    public static func normalizedID(_ value: String?) -> String? {
        guard let value, value.count == 16, value.unicodeScalars.allSatisfy({ (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value) }) else { return nil }
        return value.uppercased()
    }

    private static func assessVerified(_ game: Game, _ inventory: InstalledInventory) -> InstallationAssessment {
        let local = game.contents
        let bases = local.filter { $0.kind == .base }
        guard !bases.isEmpty, bases.allSatisfy({ normalizedID($0.titleID) != nil }) else {
            return result(.unknown, "本地缺少可可靠匹配的本体身份", inventory)
        }
        let known = inventory.records.filter { normalizedID($0.titleID) != nil }
        let installedBases = bases.filter { base in
            known.contains { $0.kind == .base && normalizedID($0.titleID) == normalizedID(base.titleID) }
        }
        let allDeviceIdentitiesKnown = inventory.records.allSatisfy { normalizedID($0.titleID) != nil && $0.kind != .unknown }
        let absenceIsEvidence = inventory.isComplete && allDeviceIdentitiesKnown
        let localIDs = Set(local.compactMap { normalizedID($0.titleID) })
        let anyRelatedInstalled = known.contains { record in normalizedID(record.titleID).map(localIDs.contains) ?? false }
        if installedBases.isEmpty {
            if anyRelatedInstalled && absenceIsEvidence {
                return result(.partial, "检测到更新或 DLC，但设备清单中缺少本体", inventory)
            }
            if absenceIsEvidence { return result(.notInstalled, "完整设备清单中未发现此游戏的本体", inventory) }
            return result(.unknown, "设备清单或身份信息不完整，无法确认本体是否安装", inventory)
        }
        if installedBases.count != bases.count {
            return result(absenceIsEvidence ? .partial : .unknown, "本地包含多个本体候选，需要核对具体发行", inventory)
        }
        // Compare one highest known version per update identity, not every duplicate file.
        let comparable = Dictionary(grouping: local.filter { $0.kind == .update || $0.kind == .dlc }, by: { normalizedID($0.titleID) ?? "unknown:\($0.id)" })
        var missing = 0
        var uncertain = false
        for candidates in comparable.values {
            guard let first = candidates.first, let id = normalizedID(first.titleID) else { uncertain = true; continue }
            let matches = known.filter { normalizedID($0.titleID) == id && $0.kind == first.kind }
            if matches.isEmpty {
                if absenceIsEvidence { missing += 1 } else { uncertain = true }
                continue
            }
            if first.kind == .update {
                guard candidates.allSatisfy({ $0.rawVersion != nil }),
                      let expected = candidates.compactMap(\.rawVersion).max(),
                      let actual = matches.compactMap(\.rawVersion).max() else { uncertain = true; continue }
                if actual < expected { missing += 1 }
            }
        }
        if missing > 0 { return result(.partial, "本体已安装，另有 \(missing) 项本地更新或 DLC 待安装", inventory) }
        if uncertain { return result(.installed, "本体已安装，部分更新或 DLC 状态未知", inventory) }
        return result(.installed, "已确认本体存在，本地可比内容无已知缺项", inventory)
    }

    private static func assessFilename(_ game: Game, _ inventory: InstalledInventory) -> InstallationAssessment {
        let local = game.contents
        let bases = local.filter { $0.kind == .base }
        guard !bases.isEmpty, bases.allSatisfy({ normalizedID($0.titleID) != nil }) else {
            return result(.unknown, filenameNote("本地缺少可核对的本体 Title ID。"), inventory)
        }
        let known = inventory.records.filter { normalizedID($0.titleID) != nil }
        let installedBases = bases.filter { base in
            known.contains { $0.kind == .base && normalizedID($0.titleID) == normalizedID(base.titleID) }
        }
        let allDeviceIdentitiesKnown = inventory.records.allSatisfy { normalizedID($0.titleID) != nil && $0.kind != .unknown }
        let absenceIsEvidence = inventory.isComplete && allDeviceIdentitiesKnown
        if installedBases.isEmpty {
            if absenceIsEvidence {
                return result(.notInstalled, filenameNote("完整且身份齐全的清单中没有本体，视为未安装。"), inventory)
            }
            return result(.unknown, filenameNote("清单或身份不完整，无法确认本体是否安装。"), inventory)
        }
        if installedBases.count != bases.count {
            if absenceIsEvidence {
                return result(.partial, filenameNote("本地有多个本体，设备清单未全部对应，视为部分安装。"), inventory)
            }
            return result(.unknown, filenameNote("本地有多个本体，清单不完整，无法确认。"), inventory)
        }
        let comparable = Dictionary(grouping: local.filter { $0.kind == .update || $0.kind == .dlc }, by: { normalizedID($0.titleID) ?? "unknown:\($0.id)" })
        var missing = 0
        var uncertain = false
        for candidates in comparable.values {
            guard let first = candidates.first, let id = normalizedID(first.titleID) else { uncertain = true; continue }
            let matches = known.filter { normalizedID($0.titleID) == id && $0.kind == first.kind }
            if matches.isEmpty {
                if absenceIsEvidence { missing += 1 } else { uncertain = true }
                continue
            }
            guard candidates.allSatisfy({ $0.rawVersion != nil }),
                  let expected = candidates.compactMap(\.rawVersion).max(),
                  let actual = matches.compactMap(\.rawVersion).max() else { uncertain = true; continue }
            if actual < expected { missing += 1 }
        }
        if missing > 0 {
            return result(.partial, filenameNote("本体在设备清单中，另有 \(missing) 项本地更新或 DLC 缺失或版本更低，视为部分安装。"), inventory)
        }
        if uncertain {
            return result(.installed, filenameNote("本体 Title ID 与内容类型一致，视为已安装；部分更新或 DLC 无法对照。"), inventory)
        }
        return result(.installed, filenameNote("本体 Title ID 与内容类型一致，本地可比更新与 DLC 无已知缺项，视为已安装。"), inventory)
    }

    private static func filenameNote(_ body: String) -> String {
        "文件名 Title ID 与当前设备清单对照：\(body)包字节未验证。"
    }

    private static func note(_ filenameIdentity: Bool, _ body: String) -> String {
        filenameIdentity ? filenameNote(body) : body
    }

    private static func result(_ state: InstallationState, _ message: String, _ inventory: InstalledInventory? = nil) -> InstallationAssessment {
        InstallationAssessment(state: state, explanation: message, observedAt: inventory?.observedAt)
    }
}
