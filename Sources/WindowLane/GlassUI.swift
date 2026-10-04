import AppKit
import SwiftUI

private enum LaneGlassPreferences {
    // Local diagnostic flags exercise our fallback without changing system settings.
    static let previewOpaque = CommandLine.arguments.contains("--ui-preview-reduce-transparency")
        || CommandLine.arguments.contains("--ui-preview-high-contrast")
}

/// One material owner for manager cards, the workspace rail and preview controls.
struct LaneGlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

private struct LaneGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let radius: CGFloat
    let selected: Bool

    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if reduceTransparency || contrast == .increased || LaneGlassPreferences.previewOpaque {
            content
                .background(Theme.surface, in: shape)
                .overlay(shape.strokeBorder(selected ? Theme.primary : Theme.muted,
                                            lineWidth: selected ? 2 : 1))
        } else if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
                .overlay(shape.strokeBorder(selected ? Theme.primary.opacity(0.55) : Theme.glassRim,
                                            lineWidth: selected ? 1.5 : 0.5))
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(selected ? Theme.primary : Theme.glassRim,
                                            lineWidth: selected ? 1.5 : 0.5))
        }
    }
}

extension View {
    func laneGlass(radius: CGFloat = Theme.cardRadius, selected: Bool = false) -> some View {
        modifier(LaneGlassSurface(radius: radius, selected: selected))
    }

    func laneGlassButton(prominent: Bool = false) -> some View {
        modifier(LaneGlassButtonPresentation(prominent: prominent))
    }
}

private struct LaneGlassButtonPresentation: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let prominent: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency,
           contrast != .increased, !LaneGlassPreferences.previewOpaque {
            if prominent { content.buttonStyle(.glassProminent).tint(Theme.primary) }
            else { content.buttonStyle(.glass).tint(nil as Color?) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent).tint(Theme.primary) }
            else { content.buttonStyle(.bordered).tint(nil as Color?) }
        }
    }
}

/// Window-level translucency uses AppKit's compositor rather than a painted blur.
private struct LaneWindowMaterial: NSViewRepresentable {
    var transparency: Double
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        view.alphaValue = 1 - transparency
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.alphaValue = 1 - transparency }
}

enum LaneBackgroundSurface {
    case application, settings
}

struct LaneWindowBackground: View {
    @ObservedObject var settings: BackgroundSettings
    var surface: LaneBackgroundSurface = .application
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    private var transparency: Double {
        surface == .settings ? settings.settingsTransparency : settings.transparency
    }
    var body: some View {
        Group {
            if reduceTransparency || contrast == .increased || LaneGlassPreferences.previewOpaque { Theme.canvas }
            else if settings.mode == .wallpaper, let image = settings.image {
                GeometryReader { geometry in
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width + settings.blur * 4,
                               height: geometry.size.height + settings.blur * 4)
                        .blur(radius: settings.blur, opaque: true)
                        .overlay(Theme.canvas.opacity(0.12))
                        .offset(x: -settings.blur * 2, y: -settings.blur * 2)
                        .opacity(1 - transparency)
                }.clipped()
            } else { LaneWindowMaterial(transparency: transparency) }
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}
