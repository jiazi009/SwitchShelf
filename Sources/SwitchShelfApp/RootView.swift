import SwiftUI
import SwitchShelfDomain

struct RootView: View {
    @Bindable var model: AppModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView(model: model)
                    .navigationSplitViewColumnWidth(min: 214, ideal: 236, max: 286)
            } detail: {
                if model.games.isEmpty {
                    // On macOS, attaching even a hidden inspector to the empty
                    // library can loop NSHostingView/NSWindow size constraints.
                    // Do not install the native inspector until it has content.
                    detail
                } else {
                    detail
                        .inspector(isPresented: Binding(
                            get: { model.inspectorPresented && model.isLibraryPage },
                            set: { model.inspectorPresented = $0 }
                        )) {
                            InspectorView(model: model)
                                .inspectorColumnWidth(min: 300, ideal: 336, max: 440)
                        }
                }
            }
        .navigationSplitViewStyle(.balanced)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            model.adaptInspector(to: width)
        }
        .background(WindowWash())
        .frame(minWidth: 960, maxWidth: .infinity, minHeight: 640, maxHeight: .infinity)
        .background(WindowChrome())
        .tint(Theme.accent)
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .alert(
            "移除来源？",
            isPresented: Binding(
                get: { model.sourcePendingRemoval != nil },
                set: { if !$0 { model.sourcePendingRemoval = nil } }
            ),
            presenting: model.sourcePendingRemoval
        ) { source in
            Button("移除来源", role: .destructive) {
                model.removeSource(source)
            }
            Button("取消", role: .cancel) {
                model.sourcePendingRemoval = nil
            }
        } message: { source in
            Text("将移除「\(source.name)」及其缓存条目。磁盘上的游戏文件不会被移动或删除。")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection ?? .all {
        case .queue:
            QueueView(model: model)
        case .device:
            DeviceView(model: model)
        case .wifi:
            WiFiConnectView(model: model)
        case .maintenance:
            MaintenanceView(model: model)
        case .all, .recent, .unidentified, .source:
            LibraryView(model: model)
        }
    }
}
