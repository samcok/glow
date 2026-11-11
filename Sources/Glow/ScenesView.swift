import SwiftUI

enum SceneMode: Equatable { case idle, creating, renaming(String), deleting(String) }

/// Text field that appears in place: Enter saves, Esc cancels.
struct InlineField: View {
    let prompt: LocalizedStringKey
    @Binding var text: String
    let commit: () -> Void
    let cancel: () -> Void
    @FocusState private var focus: Bool

    var body: some View {
        TextField(prompt, text: $text).textFieldStyle(.roundedBorder).focused($focus)
            .onSubmit(commit).onExitCommand(perform: cancel)
            .onAppear { focus = true }
            .accessibilityLabel(prompt)
    }
}

struct ScenesView: View {
    let hue: Hue
    let room: Room
    let tint: Color
    let compact: Bool
    @StateObject private var mode = Box(SceneMode.idle)
    @StateObject private var name = Box("")

    private func commit() {
        defer { mode.v = .idle }
        if case .renaming(let id) = mode.v, let s = hue.scenes.first(where: { $0.id == id }) { hue.renameScene(s, name.v) }
        else if mode.v == .creating { hue.createScene(name.v, in: room) }
    }

    var body: some View {
        let scenes = hue.scenes.filter { $0.group.rid == room.id }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Scenes").font(.headline)
                Spacer()
                if mode.v == .creating {
                    InlineField(prompt: "Scene name", text: $name.v, commit: commit) { mode.v = .idle }
                        .frame(width: 200)
                } else {
                    Button { name.v = ""; mode.v = .creating } label: { Label("New scene", systemImage: "plus") }
                        .buttonStyle(.glassProminent).tint(tint).accessibilityLabel("New scene")
                }
            }
            if compact {
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(scenes) { tile($0) }
                    }
                }.frame(maxHeight: 132)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(scenes) { tile($0) }
                }
            }
        }
    }

    private func tile(_ s: HueScene) -> some View {
        SceneTile(hue: hue, scene: s, compact: compact, mode: mode.v, name: $name.v, commit: commit,
                  cancel: { mode.v = .idle }, delete: { hue.deleteScene(s); mode.v = .idle })
            .contextMenu {
                Button("Update with current state") { hue.updateScene(s, in: room) }
                Button("Rename") { name.v = s.metadata.name; mode.v = .renaming(s.id) }
                Button("Delete", role: .destructive) { mode.v = .deleting(s.id) }
            }
    }
}

struct SceneTile: View {
    let hue: Hue
    let scene: HueScene
    let compact: Bool
    let mode: SceneMode
    @Binding var name: String
    let commit: () -> Void
    let cancel: () -> Void
    let delete: () -> Void

    var body: some View {
        let colors = scene.colors.isEmpty ? [Color.secondary.opacity(0.3)] : scene.colors.map(\.color)
        let active = hue.active[scene.group.rid] == scene.id
        ZStack {
            Button { hue.recall(scene) } label: {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: colors.count > 1 ? colors : colors + colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    LinearGradient(stops: [.init(color: .clear, location: 0.45), .init(color: .black.opacity(0.5), location: 1)], startPoint: .top, endPoint: .bottom)
                    if mode != .renaming(scene.id) {
                        Text(scene.metadata.name).font((compact ? Font.caption : .callout).weight(.semibold))
                            .foregroundStyle(.white).shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                            .lineLimit(compact ? 1 : 2).padding(compact ? 8 : 10)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.buttonStyle(Press()).accessibilityLabel("Scene \(scene.metadata.name)")
            if mode == .renaming(scene.id) {
                InlineField(prompt: "New name", text: $name, commit: commit, cancel: cancel)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(6)
            }
            if mode == .deleting(scene.id) {
                VStack(spacing: 6) {
                    Text("Delete?").font(.callout.weight(.semibold)).foregroundStyle(.white)
                    HStack {
                        Button("Confirm", role: .destructive, action: delete)
                        Button("Cancel", action: cancel)
                    }.buttonStyle(.glass).controlSize(.small)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black.opacity(0.7))
            }
        }
        .frame(height: compact ? 56 : 84)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white, lineWidth: active ? 2 : 0)
            .scaleEffect(active ? 1 : 1.06).opacity(active ? 1 : 0))
        .animation(Hue.ease == nil ? nil : .spring(duration: 0.4, bounce: 0.45), value: active)
    }
}

/// Scene tile: lifts and brightens on hover, sinks slightly while pressed.
struct Press: ButtonStyle {
    func makeBody(configuration c: Configuration) -> some View { Tile(c: c) }

    struct Tile: View {
        let c: ButtonStyleConfiguration
        @StateObject private var hover = Box(false)
        var body: some View {
            let motion = Hue.ease != nil
            c.label
                .brightness(hover.v ? 0.06 : 0)
                .scaleEffect(c.isPressed ? 0.96 : (hover.v && motion ? 1.02 : 1))
                .animation(motion ? .easeOut(duration: 0.12) : nil, value: c.isPressed)
                .animation(motion ? .easeInOut(duration: 0.25) : nil, value: hover.v)
                .onHover { hover.v = $0 }
        }
    }
}
