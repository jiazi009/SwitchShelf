import AppKit
import SwiftUI
import Foundation
import SwitchShelfDevice
import SwitchShelfDomain
import Darwin

private struct FileFixtureFailure: Error, CustomStringConvertible { let description: String }

@MainActor
private enum FileFixtureChecks {
    static var assertions = 0
    static func require(_ condition: Bool, _ reason: String) throws {
        guard condition else { throw FileFixtureFailure(description: reason) }
        assertions += 1
    }
    static let signature = "usb-registry-fixture-A"
    static let discovery = DeviceDiscovery(state: .waitingForMTP, devices: [
        DeviceDescriptor(id: signature, name: "Synthetic Switch", vendorID: 0x057e, productID: 0x201d)
    ], message: "Synthetic only; no real USB access")

    static func model(root: URL, label: String, mode: String = "normal", delay: Double = 0.05) throws -> (DeviceFileManagerModel, URL) {
        let directory = root.appendingPathComponent(label, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let helper = directory.appendingPathComponent("fake-helper")
        let source = #"""
#!/usr/bin/python3
import json,os,pathlib,sys,time
base=pathlib.Path(__file__).parent
config=json.loads((base/'config.json').read_text())
work=pathlib.Path(sys.argv[3])
envelope=json.loads((work/'request.json').read_text())
request=envelope['request']; operation=request['operation']; rid=request['id']
with (base/'calls.jsonl').open('a') as f: f.write(json.dumps(request)+'\n')
time.sleep(config.get('delay',0.05))
storage={'name':'microSD card','capacityBytes':274877906944,'freeBytes':137438953472,'canUpload':True,'isReadOnly':False,'role':'普通文件存储'}
readonly={'name':'Games','canUpload':False,'isReadOnly':True,'role':'已安装内容 · 只读'}
result={'requestID':rid,'operation':operation,'outcome':'completed','storages':[],'transferredBytes':0,'releaseVerified':True,'message':'合成文件操作完成。'}
if operation=='storages': result['storages']=[storage,readonly]
elif operation=='list':
 location=request['location']; chosen=storage if location['storageName']=='microSD card' else readonly
 if not location['components']:
  rows=[('switch',True,None,None),('备份',True,None,None),('readme.txt',False,1024,'20261028T150000'),('很长的中文文件名称用于检查表格在小窗口内的布局与省略处理.json',False,65536,'20261027T131500'),('empty.bin',False,0,None)]
 else: rows=[('app.nro',False,1048576,'20261020T101500'),('notes.txt',False,512,None)]
 result['listing']={'location':location,'storage':chosen,'entries':[{'location':location,'name':name,'isDirectory':folder,**({'byteCount':size} if size is not None else {}),**({'modifiedDate':date} if date else {})} for name,folder,size,date in rows]}
elif operation=='upload': result['transferredBytes']=request['uploadSource'].get('byteCount',64)
elif operation=='download': result['transferredBytes']=request['entry'].get('byteCount',0)
if config['mode']=='unverified': result['releaseVerified']=False; result['message']='合成释放失败；后续操作必须阻止。'
response={'schemaVersion':1,'requestID':rid,'result':result}
(work/'result.json').write_text(json.dumps(response,ensure_ascii=False))
os.chmod(work/'result.json',0o600)
sys.exit(0 if result['releaseVerified'] else 1)
"""#
        try Data(source.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        try JSONSerialization.data(withJSONObject: ["mode": mode, "delay": delay]).write(to: directory.appendingPathComponent("config.json"))
        let model = DeviceFileManagerModel(client: BoundedDeviceFileClient(helperURL: helper))
        model.setDeviceSignature(signature)
        return (model, directory)
    }
    static func calls(_ directory: URL) -> Int {
        (try? String(contentsOf: directory.appendingPathComponent("calls.jsonl"), encoding: .utf8).split(separator: "\n").count) ?? 0
    }

    static func run(root: URL, output: URL) async throws {
        let (files, directory) = try model(root: root, label: "normal")
        try require(files.blocker == nil, "Connected synthetic session should permit browsing")
        files.refreshStorages()
        try require(files.isBusy, "Browsing locks USB synchronously before launching the task")
        await files.waitForDeviceFileFixture()
        try require(files.storages.count == 2 && !files.isBusy, "Storage response must publish only after helper settlement")
        files.openStorage(files.storages[0])
        await files.waitForDeviceFileFixture()
        try require(files.location == MTPFileLocation(storageName: "microSD card") && files.visibleEntries.count == 5,
                    "Storage selection must list its logical root")
        try require(files.visibleEntries.prefix(2).allSatisfy(\.isDirectory), "Directories must sort before files")
        try require(files.canUpload, "Ordinary writable microSD allows upload")
        files.searchText = "README"
        try require(files.visibleEntries.map(\.name) == ["readme.txt"], "Filename search must ignore case")
        files.searchText = ""
        let originalEntries = files.listing!.entries
        let unknown = MTPFileEntry(location: files.location!, name: "unknown.bin", isDirectory: false)
        let oversized = MTPFileEntry(location: files.location!, name: "oversized.bin", isDirectory: false, byteCount: 4_294_967_296)
        let duplicate = MTPFileEntry(location: files.location!, name: "duplicate.txt", isDirectory: false, byteCount: 1)
        files.replaceDeviceFileEntriesFixture(originalEntries + [unknown, oversized, duplicate, duplicate])
        files.selectedEntryID = files.visibleRows.first(where: { $0.entry.name == "unknown.bin" })?.id
        try require(!files.canDownload && files.downloadIssue != nil, "Unknown file size must block the download picker with a reason")
        files.selectedEntryID = files.visibleRows.first(where: { $0.entry.name == "oversized.bin" })?.id
        try require(!files.canDownload && files.downloadIssue != nil, "Files over the transfer cap must not open a download picker")
        try require(Set(files.visibleRows.map(\.id)).count == files.visibleRows.count, "Duplicate filenames must retain unique native table row identities")
        files.selectedEntryID = files.visibleRows.first(where: { $0.entry.name == "duplicate.txt" })?.id
        try require(!files.canDownload && files.downloadIssue != nil, "Ambiguous duplicate names cannot be downloaded")
        files.replaceDeviceFileEntriesFixture(originalEntries)
        files.selectedEntryID = files.visibleRows.first(where: { $0.entry.name == "readme.txt" })?.id
        try require(files.canDownload && !files.canOpenSelection, "A file selection offers download rather than folder navigation")
        let selected = files.selectedEntry!
        files.download(entry: selected, to: root.appendingPathComponent("synthetic-download.txt"))
        await files.waitForDeviceFileFixture()
        try require(files.messageIsError == false && calls(directory) == 3, "Explicit download must execute one direct fake helper")
        let beforeProtected = calls(directory)
        files.download(entry: selected, to: URL(fileURLWithPath: "/Volumes/switch 游戏包/do-not-write.txt"))
        try require(!files.isBusy && calls(directory) == beforeProtected && files.messageIsError,
                    "Download cannot write to the protected game source")
        files.upload(sourceURL: URL(fileURLWithPath: "/Volumes/switch 游戏包/do-not-read.txt"), to: files.location!)
        try require(!files.isBusy && calls(directory) == beforeProtected, "Upload cannot read protected game sources")
        files.upload(sourceURL: root.appendingPathComponent("game.nsp"), to: files.location!)
        try require(!files.isBusy && calls(directory) == beforeProtected, "Generic upload cannot bypass the installation path with NSP")
        let ordinary = root.appendingPathComponent("ordinary.txt")
        try Data(repeating: 0x41, count: 64).write(to: ordinary)
        files.upload(sourceURL: ordinary, to: files.location!)
        await files.waitForDeviceFileFixture()
        try require(!files.messageIsError && calls(directory) == beforeProtected + 1, "Ordinary file upload must use the reviewed upload request")
        files.refreshCurrentFolder()
        await files.waitForDeviceFileFixture()
        files.open(files.listing!.entries.first(where: \.isDirectory)!)
        await files.waitForDeviceFileFixture()
        try require(files.location?.components.count == 1 && files.visibleEntries.count == 2,
                    "Opening a folder must carry logical path components")
        files.goUp()
        await files.waitForDeviceFileFixture()
        try require(files.location?.components.isEmpty == true, "Up navigation must return to the storage root")
        try require(files.canGoBack, "Successful navigation must retain logical back history")
        files.goBack()
        await files.waitForDeviceFileFixture()
        try require(files.location?.components.count == 1, "Back must re-resolve and return to the previous folder")
        files.goUp()
        await files.waitForDeviceFileFixture()
        files.openStorage(files.storages[1])
        await files.waitForDeviceFileFixture()
        try require(files.currentStorage?.name == "Games" && !files.canUpload, "Virtual Games entry must remain read-only")
        print("PASS: file browsing/navigation/search/sort, selection, ordinary transfers and source restrictions")

        let (stale, staleDirectory) = try model(root: root, label: "stale", delay: 0.7)
        stale.refreshStorages()
        try await Task.sleep(for: .milliseconds(100))
        stale.setDeviceSignature("usb-registry-fixture-B")
        try require(stale.isBusy, "Disconnect/change cannot unlock before the previous direct helper settles")
        await stale.waitForDeviceFileFixture()
        try require(stale.storages.isEmpty && stale.listing == nil && !stale.isBusy,
                    "A stale response cannot repopulate a replacement device session")
        try require(calls(staleDirectory) <= 1, "Session invalidation must not retry automatically")
        let (cancelled, _) = try model(root: root, label: "cancel", delay: 1)
        cancelled.refreshStorages()
        try await Task.sleep(for: .milliseconds(100))
        cancelled.cancel()
        try require(cancelled.isBusy, "Cancel keeps the busy flag until exit verification")
        await cancelled.waitForDeviceFileFixture()
        try require(!cancelled.isBusy && cancelled.storages.isEmpty, "Cancelled browse cannot publish stale storage data")
        print("PASS: session generation invalidation and cancellation retain exclusive ownership")

        let (integrated, _) = try model(root: root, label: "integration", delay: 0.5)
        let app = AppModel(appDirectory: root.appendingPathComponent("app-state"), discoverDevice: { discovery },
                           fileManager: integrated)
        try app.seedDeviceFileIntegration(root)
        try require(app.canReadInventory && app.canBeginStagedInstallation,
                    "Integration fixture must be eligible before file access begins")
        integrated.refreshStorages()
        try require(!app.canReadInventory && !app.canBeginStagedInstallation,
                    "An active file helper must block inventory and installation")
        let phase = app.wifi.phase
        await app.connectWiFi()
        try require(app.wifi.phase == phase && !app.isWiFiBusy && app.notice?.title == "USB 会话还在进行",
                    "File access must block FTP before any network connection")
        await integrated.waitForDeviceFileFixture()
        try require(app.canReadInventory && app.canBeginStagedInstallation, "Verified file-helper exit releases global operation gates")
        let (fenced, fenceDirectory) = try model(root: root, label: "fence", mode: "unverified")
        let fencedApp = AppModel(appDirectory: root.appendingPathComponent("fenced-app-state"), discoverDevice: { discovery },
                                 fileManager: fenced)
        try fencedApp.seedDeviceFileIntegration(root)
        fenced.refreshStorages()
        await fenced.waitForDeviceFileFixture()
        try require(fenced.hasUnverifiedWorker && !fencedApp.canReadInventory && !fencedApp.canBeginStagedInstallation,
                    "Unverified file release must fence inventory and installation beyond this operation")
        fenced.refreshStorages()
        try require(!fenced.isBusy && calls(fenceDirectory) == 1, "A fenced file client cannot launch another helper")
        print("PASS: root inventory/install/FTP exclusion and persistent unverified-release fence")

        let (visual, _) = try model(root: root, label: "visual")
        let visualApp = AppModel(appDirectory: root.appendingPathComponent("visual-app-state"), discoverDevice: { discovery },
                                 fileManager: visual)
        try visualApp.seedDeviceFileIntegration(root)
        visual.refreshStorages(); await visual.waitForDeviceFileFixture()
        visual.openStorage(visual.storages[0]); await visual.waitForDeviceFileFixture()
        visual.dismissMessage()
        var captures: [[String: Any]] = []
        for dark in [false, true] {
            for width in [960, 1280] {
                let size = NSSize(width: width, height: width == 960 ? 640 : 820)
                let scheme: ColorScheme = dark ? .dark : .light
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                NSApp.appearance = appearance
                let name = "files-\(width)x\(Int(size.height))-\(dark ? "dark" : "light")"
                captures.append(try await render(RootView(model: visualApp).environment(\.colorScheme, scheme),
                                                size: size, appearance: appearance, name: name, output: output))
            }
        }
        visual.openStorage(visual.storages[1]); await visual.waitForDeviceFileFixture(); visual.dismissMessage()
        captures.append(try await render(RootView(model: visualApp).environment(\.colorScheme, .light),
                                        size: NSSize(width: 960, height: 640), appearance: NSAppearance(named: .aqua)!,
                                        name: "files-readonly-960x640-light", output: output))
        visual.seedDeviceFileProgressFixture()
        captures.append(try await render(RootView(model: visualApp).environment(\.colorScheme, .dark),
                                        size: NSSize(width: 960, height: 640), appearance: NSAppearance(named: .darkAqua)!,
                                        name: "files-progress-960x640-dark", output: output))
        visual.clearDeviceFileProgressFixture()
        visual.setDeviceSignature(nil)
        captures.append(try await render(DeviceFilesView(model: visual).environment(\.colorScheme, .light),
                                        size: NSSize(width: 724, height: 640), appearance: NSAppearance(named: .aqua)!,
                                        name: "files-disconnected-724x640-light", output: output))
        let manifest: [String: Any] = ["fixtureOnly": true, "assertions": assertions, "captures": captures,
            "noUSBNoNASNoNetwork": true, "captureMethod": "active synthetic native NSWindow content cacheDisplay",
            "limitations": ["Fixtures establish app state/layout behavior, not device protocol acceptance or real transfer outcomes.",
                             "Native material/color appearance in cacheDisplay needs comparison with the live production app."]]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("manifest.json"))
        print("PASS: \(assertions) file-manager assertions and \(captures.count) focused native layout captures; all operations synthetic")
    }

    static func render<V: View>(_ content: V, size: NSSize, appearance: NSAppearance, name: String, output: URL) async throws -> [String: Any] {
        NSApp.appearance = appearance
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "SwitchShelf 文件管理回归（合成）"
        window.appearance = appearance
        window.contentView = hosting
        window.setContentSize(size)
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(350))
        hosting.layoutSubtreeIfNeeded()
        guard abs(hosting.bounds.width - size.width) < 2, abs(hosting.bounds.height - size.height) < 2,
              let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw FileFixtureFailure(description: "Native file-manager viewport was not the requested size: \(hosting.bounds)")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw FileFixtureFailure(description: "Cannot encode file-manager capture")
        }
        let file = name + ".png"
        try png.write(to: output.appendingPathComponent(file))
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        return ["file": file, "width": size.width, "height": size.height]
    }
}

@main
private struct DeviceFilesRegression {
    @MainActor static func main() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        do {
            guard CommandLine.arguments.count == 3 else { throw FileFixtureFailure(description: "Expected private fixture and output directories") }
            let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            try await FileFixtureChecks.run(root: root, output: output)
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            Darwin.exit(1)
        }
    }
}
