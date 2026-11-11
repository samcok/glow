import SwiftUI

extension View {
    /// Liquid Glass content panel.
    func panel(_ padding: CGFloat = 16) -> some View {
        self.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
    }
}

/// Light dot used on the wheel and the temperature bar: a glass circle tinted with the light's colour.
/// Pointer hover feedback: slight brighten, plus an optional lift. Lift is skipped with Reduce Motion.
struct HoverLift: ViewModifier {
    let scale: CGFloat
    @StateObject private var hover = Box(false)
    func body(content: Content) -> some View {
        let motion = Hue.ease != nil
        content
            .brightness(hover.v ? 0.06 : 0)
            .scaleEffect(hover.v && motion ? scale : 1)
            .animation(motion ? .easeInOut(duration: 0.25) : nil, value: hover.v)
            .onHover { hover.v = $0 }
    }
}

extension View {
    func hoverLift(scale: CGFloat = 1) -> some View { modifier(HoverLift(scale: scale)) }
}

struct LightDot: View {
    let light: Light
    let picked: Bool
    let dragging: Bool

    var body: some View {
        Text(String(light.metadata.name.prefix(1))).font(.caption.bold()).foregroundStyle(.black.opacity(0.65))
            .frame(width: 28, height: 28)
            .glassEffect(.regular.tint(light.rgb.color).interactive(), in: .circle)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2).opacity(picked ? 1 : 0))
            .scaleEffect(dragging ? 1.15 : 1)
            .opacity(light.on.on ? 1 : 0.5)
            .animation(.easeOut(duration: 0.12), value: dragging)
            .hoverLift(scale: 1.1)
            .accessibilityLabel(picked ? Text("\(light.metadata.name), selected") : Text(light.metadata.name))
    }
}

/// Soft blurred glow built from the colours of the room's lights that are on.
struct RoomGlow: View {
    let hue: Hue
    let room: Room?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let lights = room.map { hue.lights(in: $0).filter(\.on.on) } ?? []
        GeometryReader { g in
            ZStack {
                ForEach(Array(lights.enumerated()), id: \.element.id) { i, l in
                    let f = lights.count > 1 ? Double(i) / Double(lights.count - 1) : 0.5
                    Circle().fill(l.rgb.color)
                        .frame(width: g.size.width * 0.7, height: g.size.width * 0.7)
                        .blur(radius: 90)
                        .opacity((scheme == .dark ? 1 : 0.6) * (0.10 + 0.16 * (l.dimming?.brightness ?? 100) / 100))
                        .position(x: g.size.width * (0.15 + 0.7 * f), y: g.size.height * (i % 2 == 0 ? 0.12 : 0.3))
                }
            }
            .animation(Hue.ease, value: lights.map(\.rgb.r) + lights.map(\.rgb.g) + lights.map(\.rgb.b) + lights.map { $0.dimming?.brightness ?? 0 })
        }
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Display positions: points that are close together fan out side by side (28pt slots), by id order.
func fanOut(_ pts: [(id: String, p: CGPoint)], near: (CGPoint, CGPoint) -> Bool) -> [String: CGPoint] {
    var out: [String: CGPoint] = [:]
    for a in pts {
        let group = pts.filter { near($0.p, a.p) }.sorted { $0.id < $1.id }
        let slot = group.firstIndex { $0.id == a.id } ?? 0
        out[a.id] = CGPoint(x: a.p.x + [0, 28, -28, 56, -56][min(slot, 4)], y: a.p.y)
    }
    return out
}
