import Foundation
import Testing
import SwitchShelfDomain
@testable import SwitchShelfLibrary

@Suite("Real NAS Scan Tests")
struct RealNASScanTests {
    @Test("Bounded read-only scan of real NAS volume if mounted")
    func realNASBoundedScan() async throws {
        let nasPath = "/Volumes/switch 游戏包"
        guard FileManager.default.fileExists(atPath: nasPath) else {
            // Volume not mounted in this environment; skip test gracefully
            return
        }

        let nasURL = URL(fileURLWithPath: nasPath)
        let source = LibrarySource(
            id: "real-nas-source",
            url: nasURL,
            name: "switch 游戏包",
            availability: .unknown
        )

        let startTime = ContinuousClock.now
        let scanner = LibraryScanner()
        let snapshot = try await scanner.scan(source)
        let elapsedTime = ContinuousClock.now - startTime

        print("=== Real NAS Scan Evidence ===")
        print("Scanned Volume: \(nasPath)")
        print("Elapsed Time: \(elapsedTime)")
        print("Discovered Games: \(snapshot.games.count)")
        let totalContents = snapshot.games.reduce(0) { $0 + $1.contents.count }
        let totalBytes = snapshot.games.reduce(Int64(0)) { $0 + $1.byteCount }
        print("Discovered Total Packages: \(totalContents)")
        print("Discovered Total Bytes: \(totalBytes) bytes (\(Double(totalBytes) / 1_000_000_000.0) GB)")
        print("Issues Encountered: \(snapshot.issues.count)")

        for game in snapshot.games.prefix(10) {
            let baseCount = game.contents.filter { $0.kind == .base }.count
            let updCount = game.contents.filter { $0.kind == .update }.count
            let dlcCount = game.contents.filter { $0.kind == .dlc }.count
            print("  • \(game.title) [\(game.id)] (Base: \(baseCount), UPD: \(updCount), DLC: \(dlcCount)) - \(game.identification)")
        }

        #expect(snapshot.games.count > 0)
        #expect(snapshot.sources.first?.availability == .online)
    }
}
