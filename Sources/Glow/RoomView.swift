import SwiftUI

struct RoomView: View {
    let hue: Hue
    let room: Room
    var compact = false
    @StateObject private var selection = Box(Set<String>())
    @StateObject private var white = Box(false)
    private var sel: Set<String> { get { selection.v } nonmutating set { selection.v = newValue } }

    var body: some View {
        let lights = hue.lights(in: room)
        let tint = hue.tint(room)
        let size: CGFloat = compact ? 220 : 280
        let g = room.groupID ?? ""
        let roomOn = Binding(get: { hue.groups[g]?.on?.on ?? false }, set: { hue.setGroupOn(g, $0) })
        let all = !lights.isEmpty && lights.allSatisfy { sel.contains($0.id) }
        let toggleAll = Button { sel = all ? [] : Set(lights.map(\.id)) } label: {
            Label(all ? "Deselect" : "Select all", systemImage: all ? "xmark.circle" : "checkmark.circle")
        }.labelStyle(.titleAndIcon).buttonStyle(.glass).accessibilityLabel(all ? "Deselect lights" : "Select all lights")
        let colorPanel = VStack(spacing: 12) {
            Picker("Mode", selection: Binding(get: { white.v ? 1 : 0 }, set: { white.v = $0 == 1 })) {
                Text("Color").tag(0)
                Text("White").tag(1)
            }.pickerStyle(.segmented).labelsHidden()
            if compact { HStack { Spacer(); toggleAll } }
            control(lights, size)
        }.frame(width: size)
        let content = GlassEffectContainer(spacing: 0) {
            VStack(alignment: .leading, spacing: compact ? 12 : 16) {
                if let e = hue.error { Text(e).font(.caption).foregroundStyle(.red) }
                brightness(g, tint, roomOn)
                if compact {
                    colorPanel.panel(12).frame(maxWidth: .infinity)
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        colorPanel.panel().fixedSize(horizontal: true, vertical: false)
                        lightsPanel(lights, toggleAll)
                    }
                }
                ScenesView(hue: hue, room: room, tint: tint, compact: compact).panel(compact ? 12 : 16)
            }.padding(compact ? 16 : 20)
        }
        Group { if compact { content } else { ScrollView { content } } }
        .navigationTitle(room.metadata.name)
        .toolbar {
            if !compact {
                ToolbarItem { Toggle("Room on", isOn: roomOn).toggleStyle(.switch).tint(tint) }
            }
        }
    }

    @ViewBuilder private func control(_ lights: [Light], _ size: CGFloat) -> some View {
        if white.v { TempBar(hue: hue, lights: lights, size: size, sel: $selection.v) }
        else { Disc(hue: hue, lights: lights, size: size, sel: $selection.v) }
    }

    private func brightness(_ g: String, _ tint: Color, _ roomOn: Binding<Bool>) -> some View {
        let b = hue.groups[g]?.dimming?.brightness ?? 0
        return HStack(spacing: 12) {
            if compact { Toggle("Room on", isOn: roomOn).labelsHidden().toggleStyle(.switch).tint(tint) }
            Slider(value: Binding(get: { b }, set: { hue.setGroupBrightness(g, $0) }), in: 0...100) {
                EmptyView()
            } minimumValueLabel: { Image(systemName: "sun.min") } maximumValueLabel: { Image(systemName: "sun.max") }
                .tint(tint).hoverLift().accessibilityLabel("Room brightness").accessibilityValue("\(Int(b.rounded())) %")
            Text("\(Int(b.rounded())) %").font(.body).monospacedDigit().contentTransition(.numericText(value: b)).foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }.panel(compact ? 12 : 16)
    }

    private func lightsPanel(_ lights: [Light], _ toggleAll: some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Lights").font(.headline); Spacer(); toggleAll }
            VStack(spacing: 0) {
                ForEach(Array(lights.enumerated()), id: \.element.id) { i, l in
                    if i > 0 { Divider() }
                    row(l)
                }
            }
        }.frame(maxWidth: .infinity).panel()
    }

    private func row(_ l: Light) -> some View {
        let picked = sel.contains(l.id)
        let c = l.rgb.color
        let b = l.dimming?.brightness ?? 0
        return HStack(spacing: 12) {
            HStack(spacing: 8) {
                // Selection shows as a checkmark in place of the color dot, to leave width for the slider.
                if picked { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor).frame(width: 14) }
                else { Circle().fill(c).frame(width: 12, height: 12).opacity(l.on.on ? 1 : 0.4).frame(width: 14) }
                Text(l.metadata.name).font(.body).lineLimit(1)
                Spacer(minLength: 0)
            }.frame(width: 104)
            .contentShape(Rectangle())
            .onTapGesture { if picked { sel.remove(l.id) } else { sel.insert(l.id) } }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(picked ? Text("\(l.metadata.name), selected") : Text(l.metadata.name))
            if l.dimming != nil {
                Slider(value: Binding(get: { b }, set: { hue.setBrightness(picked ? sel : [l.id], $0) }), in: 0...100) { EmptyView() }
                    .tint(c).hoverLift().frame(maxWidth: .infinity)
                    .accessibilityLabel("\(l.metadata.name) brightness").accessibilityValue("\(Int(b.rounded())) %")
                Text("\(Int(b.rounded())) %").font(.callout).monospacedDigit().contentTransition(.numericText(value: b)).foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            } else { Spacer(minLength: 0) }
            Toggle(l.metadata.name, isOn: Binding(get: { l.on.on }, set: { hue.setOn(l.id, $0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(c)
        }.padding(.vertical, 8)
    }
}

/// Colour wheel: hue = angle, saturation = radius.
struct Disc: View {
    let hue: Hue
    let lights: [Light]
    let size: CGFloat
    @Binding var sel: Set<String>
    @StateObject private var drag = Box<String?>(nil)

    private var c: CGFloat { size / 2 }
    private var cands: [Light] { lights.filter { $0.color != nil } }

    private var shown: [String: CGPoint] { fanOut(cands.map { ($0.id, point($0)) }) { hypot($0.x - $1.x, $0.y - $1.y) < 14 } }

    private func point(_ l: Light) -> CGPoint {
        let (h, s) = HueColor.hs(l.color!.xy)
        return CGPoint(x: c + cos(h * 2 * .pi) * s * c, y: c + sin(h * 2 * .pi) * s * c)
    }

    private func move(_ l: Light, _ p: CGPoint, end: Bool) {
        drag.v = end ? nil : l.id
        let ids = sel.contains(l.id) ? sel.intersection(cands.map(\.id)) : [l.id]
        var q = p
        let r = hypot(p.x - c, p.y - c)
        if r > c { q = CGPoint(x: c + (p.x - c) * c / r, y: c + (p.y - c) * c / r) }
        let dx = q.x - c, dy = q.y - c
        var h = atan2(dy, dx) / (2 * .pi); if h < 0 { h += 1 }
        hue.setXY(ids, HueColor.xy(h: h, s: min(hypot(dx, dy) / c, 1)))
        // dropped on another dot: take its exact value
        guard end, let o = cands.first(where: { !ids.contains($0.id) && hypot(point($0).x - q.x, point($0).y - q.y) < 16 }) else { return }
        hue.setXY(ids, o.color!.xy)
    }

    var body: some View {
        let shown = shown
        return ZStack {
            ZStack {
                Circle().fill(AngularGradient(colors: stride(from: 0.0, through: 1, by: 1.0 / 12).map { Color(hue: $0, saturation: 1, brightness: 1) }, center: .center))
                Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: c))
            }.overlay(Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
            ForEach(cands) { l in
                LightDot(light: l, picked: sel.contains(l.id), dragging: drag.v == l.id)
                    .position(shown[l.id] ?? point(l))
                    .onTapGesture { if sel.contains(l.id) { sel.remove(l.id) } else { sel.insert(l.id) } }
                    .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("disc"))
                        .onChanged { move(l, $0.location, end: false) }
                        .onEnded { move(l, $0.location, end: true) })
            }
        }
        .frame(width: size, height: size)
        .coordinateSpace(name: "disc")
    }
}

/// Vertical temperature bar: top = cool, bottom = warm. Each light's mirek range maps onto the full height.
struct TempBar: View {
    let hue: Hue
    let lights: [Light]
    let size: CGFloat
    @Binding var sel: Set<String>
    @StateObject private var drag = Box<String?>(nil)

    private let pad: CGFloat = 13
    private var cands: [Light] { lights.filter { $0.color_temperature != nil } }
    private func y(_ l: Light) -> CGFloat { pad + CGFloat(l.color_temperature!.t) * (size - 2 * pad) }

    /// Dots at the same height fan out left and right.
    private var shown: [String: CGPoint] { fanOut(cands.map { ($0.id, CGPoint(x: 65, y: y($0))) }) { abs($0.y - $1.y) < 24 } }

    private func move(_ l: Light, _ py: CGFloat, end: Bool) {
        drag.v = end ? nil : l.id
        let ids = sel.contains(l.id) ? sel.intersection(cands.map(\.id)) : [l.id]
        let t = Double(min(max((py - pad) / (size - 2 * pad), 0), 1))
        for id in ids { if let ct = hue.lights[id]?.color_temperature { hue.setMirek(id, ct.mirek(t: t)) } }
        // dropped level with another dot: take its exact value
        guard end, let o = cands.first(where: { !ids.contains($0.id) && abs(y($0) - py) < 14 }), let m = o.color_temperature?.mirek else { return }
        for id in ids { hue.setMirek(id, m) }
    }

    var body: some View {
        let shown = shown
        return ZStack {
            Capsule().fill(LinearGradient(colors: [HueColor.white(0).color, HueColor.white(1).color], startPoint: .top, endPoint: .bottom))
                .frame(width: 44, height: size).position(x: 65, y: size / 2)
                .overlay(Capsule().strokeBorder(.primary.opacity(0.2), lineWidth: 1).frame(width: 44, height: size).position(x: 65, y: size / 2))
                .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
            ForEach(cands) { l in
                LightDot(light: l, picked: sel.contains(l.id), dragging: drag.v == l.id)
                    .position(shown[l.id] ?? .zero)
                    .onTapGesture { if sel.contains(l.id) { sel.remove(l.id) } else { sel.insert(l.id) } }
                    .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("bar"))
                        .onChanged { move(l, $0.location.y, end: false) }
                        .onEnded { move(l, $0.location.y, end: true) })
            }
        }
        .frame(width: 130, height: size)
        .coordinateSpace(name: "bar")
    }
}
