import SwiftUI
import SwitchShelfDomain

struct RootView: View {
    @Bindable var model: AppModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.installationAnimationsEnabled) private var animationsEnabled
    @Namespace private var installationMotion

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 214, ideal: 236, max: 286)
        } detail: {
            pageContent
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .background(WindowWash())
        .frame(minWidth: 960, maxWidth: .infinity, minHeight: 640, maxHeight: .infinity)
        .background(WindowChrome())
        .tint(Theme.accent)
        .transaction { transaction in
            if reduceMotion || !animationsEnabled {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .onChange(of: model.isLibraryPage) { _, isLibrary in
            if !isLibrary { model.closeGameDetails() }
        }
        .alert("移除来源？", isPresented: Binding(
            get: { model.sourcePendingRemoval != nil },
            set: { if !$0 { model.sourcePendingRemoval = nil } }
        ), presenting: model.sourcePendingRemoval) { source in
            Button("移除来源", role: .destructive) { model.removeSource(source) }
            Button("取消", role: .cancel) { model.sourcePendingRemoval = nil }
        } message: { source in
            Text("将移除「\(source.name)」及其缓存条目。磁盘上的游戏文件不会被移动或删除。")
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        if model.isLibraryPage {
            HStack(spacing: 0) {
                LibraryView(model: model, installationMotion: installationMotion)
                    .frame(minWidth: 0, maxWidth: .infinity)
                Divider().overlay(Theme.hairline)
                InstallationSidebar(model: model, installationMotion: installationMotion)
                    .frame(width: 320)
            }
        } else {
            switch model.selection ?? .all {
            case .queue: QueueView(model: model)
            case .device: DeviceView(model: model)
            case .wifi: WiFiConnectView(model: model)
            case .files:
                DeviceFilesView(model: model.deviceFileManager)
                    .task(id: model.deviceFileSessionSignature) {
                        model.syncDeviceFileSession()
                        model.deviceFileManager.loadIfNeeded()
                    }
            case .album:
                AlbumScreenshotsView(model: model.albumScreenshots)
                    .task(id: model.deviceFileSessionSignature) {
                        model.syncDeviceFileSession()
                        model.albumScreenshots.loadIfNeeded()
                    }
            case .maintenance: MaintenanceView(model: model)
            default: EmptyView()
            }
        }
    }
}
