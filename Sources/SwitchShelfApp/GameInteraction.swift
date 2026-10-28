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

/// A confirmed row leaves toward the sidebar edge. Reduced motion keeps only a
/// short fade; disabled animations also keep fixture captures deterministic.
enum InstallationStagingMotion {
    static func animation(reduceMotion: Bool, enabled: Bool) -> Animation? {
        guard enabled else { return nil }
        return reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.38)
    }

    static func transition(completed: Bool, reduceMotion: Bool, enabled: Bool) -> AnyTransition {
        guard enabled else { return .identity }
        guard !reduceMotion else { return .opacity }
        let insertion = AnyTransition.opacity.combined(with: .scale(scale: 0.94))
        let removal = completed
            ? AnyTransition.move(edge: .trailing).combined(with: .opacity)
            : insertion
        return .asymmetric(insertion: insertion, removal: removal)
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

/// Anchors the detail popover to a card or row. On macOS the requested edge is
/// the side of the anchor where the panel opens, so `.trailing` places it to the
/// right of that game.
struct GameDetailsPopover: ViewModifier {
    @Bindable var model: AppModel
    let game: Game

    func body(content: Content) -> some View {
        content.popover(
            isPresented: Binding(
                get: { model.detailGame?.id == game.id },
                set: { isPresented in
                    if !isPresented, model.detailGame?.id == game.id {
                        model.closeGameDetails()
                    }
                }
            ),
            attachmentAnchor: .point(.trailing),
            arrowEdge: .trailing
        ) {
            InspectorView(model: model, game: game)
                .frame(width: 370, height: 560)
        }
    }
}
