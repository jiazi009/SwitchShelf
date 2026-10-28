import SwiftUI

@main
struct SwitchShelfApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task {
                    await model.bootstrap()
                }
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            AppCommands(model: model)
        }

        Settings {
            SettingsView()
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("添加文件夹来源…") {
                model.chooseFolder()
            }
            .keyboardShortcut("o", modifiers: .command)

            Button("重新扫描全部来源") {
                model.scanAll()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.isScanning || model.sources.isEmpty)
        }

        CommandMenu("游戏库") {
            Button("搜索…") {
                model.focusSearch()
            }
            .keyboardShortcut("f", modifiers: .command)

            Button("全部可见游戏加入待选区") {
                model.selectAllVisible()
                model.addSelectedToQueue()
            }
            .disabled(!model.isLibraryPage || model.filteredGames.isEmpty || model.installationPlanLocked)

            Button("清除浏览选择（保留待选区）") {
                model.clearSelection()
            }
            .disabled(model.selectedGameIDs.isEmpty)

            Divider()

            Button("网格视图") {
                model.layout = .grid
            }
            .keyboardShortcut("1", modifiers: .command)

            Button("列表视图") {
                model.layout = .list
            }
            .keyboardShortcut("2", modifiers: .command)

            Divider()

            Button("查看当前游戏详情") {
                if let game = model.activeGame { model.openGameDetails(game) }
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(!model.isLibraryPage || model.activeGame == nil)

            Button("将选择加入待选区") { model.addSelectedToQueue() }
                .disabled(model.selectedGameIDs.isEmpty || model.installationPlanLocked)

            Button("全部游戏") {
                model.showAllGames()
            }
            .keyboardShortcut("0", modifiers: .command)

            Button("我的 Switch") {
                model.showDevice()
            }
            .keyboardShortcut("3", modifiers: .command)

            Button("无线连接") {
                model.showWiFi()
            }
            .keyboardShortcut("5", modifiers: .command)

            Button("维护") {
                model.showMaintenance()
            }
            .keyboardShortcut("4", modifiers: .command)
        }
    }
}
