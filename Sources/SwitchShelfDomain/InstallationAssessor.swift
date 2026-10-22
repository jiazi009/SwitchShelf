import Foundation

/// Assesses device evidence separately from local transfer history.
public enum InstallationAssessor {
    public static func assess(_ game: Game, inventory: InstalledInventory?, isCurrentSession: Bool) -> InstallationAssessment {
        guard let inventory else { return result(.unknown, "尚未读取目标设备的已安装清单") }
        guard isCurrentSession else { return result(.unknown, "仅有上次读取记录，请重新连接并刷新", inventory) }
        guard game.identification == .verified || game.identification == .matched else {
            return result(.unknown, "本地游戏身份待确认，不能仅凭名称判断安装状态", inventory)
        }
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

    public static func normalizedID(_ value: String?) -> String? {
        guard let value, value.count == 16, value.unicodeScalars.allSatisfy({ (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value) }) else { return nil }
        return value.uppercased()
    }
    private static func result(_ state: InstallationState, _ message: String, _ inventory: InstalledInventory? = nil) -> InstallationAssessment {
        InstallationAssessment(state: state, explanation: message, observedAt: inventory?.observedAt)
    }
}
