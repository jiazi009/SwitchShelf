import SwiftUI
import SwitchShelfDomain

private struct InstallationAnimationsKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var installationAnimationsEnabled: Bool {
        get { self[InstallationAnimationsKey.self] }
        set { self[InstallationAnimationsKey.self] = newValue }
    }
}

/// Shared between the original cover and its derived staging thumbnail. Source
/// package files are never moved or copied by this visual transition.
struct InstallationMotion: ViewModifier {
    let id: String
    let namespace: Namespace.ID
    var enabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.installationAnimationsEnabled) private var animationsEnabled

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceMotion || !animationsEnabled || !enabled {
            content
        } else {
            content.matchedGeometryEffect(id: id, in: namespace, properties: .frame)
        }
    }
}

struct GameDetailsButton: View {
    @Bindable var model: AppModel
    let game: Game
    var placement: LibraryLayout = .grid

    var body: some View {
        Button { model.openGameDetails(game) } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 27, height: 27)
                .background(.regularMaterial, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("查看详情，不改变待选游戏")
        .accessibilityLabel("查看\(game.title)的详情")
        .accessibilityIdentifier("game-details-\(placement.rawValue)-\(game.id)")
    }
}
