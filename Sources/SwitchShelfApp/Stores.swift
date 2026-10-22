import Foundation

enum AppSettings {
    static let refreshOnLaunch = "SwitchShelf.refreshOnLaunch"
    static let initialSourceRemoved = "SwitchShelf.initialSourceRemoved"
}

struct PlanLoadResult: Sendable {
    var items: [PlanItem]
    var error: String?
}

/// JSON storage for things the library repository does not own: the local
/// installation plan and first-seen timestamps used by "最近添加".
actor LocalPlanStore {
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    private var planURL: URL { directory.appendingPathComponent("install-plan.json") }
    private var seenURL: URL { directory.appendingPathComponent("first-seen.json") }

    func loadPlan() -> PlanLoadResult {
        do {
            guard FileManager.default.fileExists(atPath: planURL.path) else {
                return PlanLoadResult(items: [], error: nil)
            }
            let data = try Data(contentsOf: planURL)
            let items = try Self.decoder.decode([PlanItem].self, from: data)
            return PlanLoadResult(items: items, error: nil)
        } catch {
            return PlanLoadResult(items: [], error: error.localizedDescription)
        }
    }

    func savePlan(_ items: [PlanItem]) throws {
        try write(items, to: planURL)
    }

    func loadFirstSeen() -> [String: Date] {
        guard FileManager.default.fileExists(atPath: seenURL.path),
              let data = try? Data(contentsOf: seenURL),
              let dates = try? Self.decoder.decode([String: Date].self, from: data) else {
            return [:]
        }
        return dates
    }

    func saveFirstSeen(_ dates: [String: Date]) throws {
        try write(dates, to: seenURL)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
