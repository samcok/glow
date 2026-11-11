import SwiftUI

// MARK: - Models (only the fields we use)

struct On: Codable { var on: Bool }
struct Dimming: Codable { var brightness: Double? }
struct Meta: Codable { var name: String }
struct Ref: Codable { var rid: String; var rtype: String }
struct LColor: Codable { var xy: XY }
struct CT: Codable {
    struct Schema: Codable { var mirek_minimum: Int; var mirek_maximum: Int }
    var mirek: Int?
    var mirek_valid: Bool?
    var mirek_schema: Schema?
    var lo: Double { Double(mirek_schema?.mirek_minimum ?? 153) }
    var hi: Double { Double(mirek_schema?.mirek_maximum ?? 500) }
    /// 0 = coolest, 1 = warmest, on one shared 153...500 scale so equal mirek = same height whatever the bulb's own range
    static let scaleLo = 153.0, scaleHi = 500.0
    var t: Double { ((mirek.map(Double.init) ?? (lo + hi) / 2) - CT.scaleLo) / (CT.scaleHi - CT.scaleLo) }
    func mirek(t: Double) -> Int { Int((CT.scaleLo + (t.isFinite ? min(max(t, 0), 1) : 0.5) * (CT.scaleHi - CT.scaleLo)).rounded()) }
}
struct Light: Codable, Identifiable {
    var id: String
    var owner: Ref
    var metadata: Meta
    var on: On
    var dimming: Dimming?
    var color: LColor?
    var color_temperature: CT?
}
struct Room: Decodable, Identifiable {
    var id: String
    var metadata: Meta
    var children: [Ref]
    var services: [Ref]
    var groupID: String? { services.first { $0.rtype == "grouped_light" }?.rid }
}
struct GroupedLight: Decodable { var id: String; var on: On?; var dimming: Dimming? }
struct HueScene: Decodable, Identifiable {
    struct Item: Decodable { var color: LColor?; var color_temperature: CT? }
    struct Palette: Decodable { var color: [Item]?; var color_temperature: [Item]? }
    var id: String
    var metadata: Meta
    var group: Ref
    var palette: Palette?
    /// Palette as display colours (xy colours, then white temperatures).
    var colors: [RGB] {
        (palette?.color ?? []).compactMap { $0.color.map { HueColor.rgb($0.xy) } }
            + (palette?.color_temperature ?? []).compactMap { $0.color_temperature.map { HueColor.white($0.t) } }
    }
}
/// Partial resource from the event stream.
struct Patch: Decodable {
    var id: String
    var type: String
    var on: On?
    var dimming: Dimming?
    var color: PColor?
    var color_temperature: CT?
}
struct PColor: Decodable { var xy: XY? }

/// One bad item in a list must not fail the whole list.
struct Lossy<T: Decodable>: Decodable {
    let v: T?
    init(from d: Decoder) throws { v = try? T(from: d) }
}
private struct Resp<T: Decodable>: Decodable { var data: [Lossy<T>] }

/// Tiny view-local state holder (this toolchain has no SwiftUIMacros plugin, so @State is unavailable).
final class Box<T>: ObservableObject {
    @Published var v: T
    init(_ v: T) { self.v = v }
}

// MARK: - Store + API client

@MainActor @Observable final class Hue {
    var rooms: [Room] = []
    var lights: [String: Light] = [:]
    var groups: [String: GroupedLight] = [:]
    var scenes: [HueScene] = []
    var error: String?
    var active: [String: String] = [:]     // room id -> scene last recalled

    var cfg: BridgeConfig?
    var pinMismatch = false
    let demo = ProcessInfo.processInfo.environment["GLOW_DEMO"] == "1"
    var configured: Bool { demo || cfg != nil }

    @ObservationIgnored private var session = URLSession.shared
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?   // at most one event-driven refresh pending/in flight
    @ObservationIgnored private var pending: [String: [String: Any]] = [:]
    @ObservationIgnored private var lastSent: [String: Date] = [:]
    @ObservationIgnored private var touched: [String: Date] = [:]   // ignore echoes of our own writes

    init() {
        if demo { loadDemo() } else { cfg = BridgeStore.load() }
        // After sleep the old stream is often dead: reconnect (run() reloads everything).
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.start() }
        }
    }

    /// (Re)start the connection with the current config.
    func start() {
        runTask?.cancel()
        guard !demo, let c = cfg else { return }
        pinMismatch = false
        session = URLSession(configuration: .default, delegate: Trust(ip: c.ip, pin: c.pin) { [weak self] in
            Task { @MainActor in self?.pinMismatch = true }
        }, delegateQueue: nil)
        runTask = Task { await run() }
    }

    /// Remove the bridge (Keychain + defaults) and go back to setup.
    func forget() {
        runTask?.cancel()
        BridgeStore.forget()
        cfg = nil; pinMismatch = false; error = nil
        rooms = []; lights = [:]; groups = [:]; scenes = []; active = [:]
    }

    // MARK: HTTP

    private func request(_ path: String) throws -> URLRequest {
        guard let c = cfg, let url = bridgeURL(c.ip, path) else { throw URLError(.badURL) }
        var r = URLRequest(url: url)
        r.setValue(c.key, forHTTPHeaderField: "hue-application-key")
        return r
    }

    private func call(_ path: String, _ method: String = "GET", _ body: [String: Any]? = nil) async throws -> Data {
        var r = try request("/clip/v2/resource/\(path)")
        r.httpMethod = method
        if let body {
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (d, resp) = try await session.data(for: r)
        guard let code = (resp as? HTTPURLResponse)?.statusCode, code < 300 else { throw URLError(.badServerResponse) }
        return d
    }

    private func get<T: Decodable>(_ type: String) async throws -> [T] {
        return try JSONDecoder().decode(Resp<T>.self, from: try await call(type)).data.compactMap(\.v)
    }

    private func send(_ path: String, _ method: String = "PUT", _ body: [String: Any], reloadScenes: Bool = false, refresh: Bool = false) {
        guard !demo else { return }
        Task {
            do {
                _ = try await call(path, method, body)
                if reloadScenes { scenes = try await get("scene") }
                if refresh { for d in [0.5, 1.5] { try? await Task.sleep(for: .seconds(d)); await self.refresh() } }
                error = nil
            } catch { self.error = String(localized: "Bridge error: \(error.localizedDescription)") }
        }
    }

    /// Per path: first write goes out at once, later ones within 100 ms are merged and sent as one.
    private func put(_ path: String, _ body: [String: Any]) {
        if pending[path] != nil { pending[path]!.merge(body) { $1 }; return }
        pending[path] = body
        let wait = max(0, 0.1 - Date().timeIntervalSince(lastSent[path] ?? .distantPast))
        Task {
            try? await Task.sleep(for: .seconds(wait))
            let b = pending.removeValue(forKey: path) ?? [:]
            lastSent[path] = Date()
            send(path, "PUT", b)
        }
    }

    // MARK: Load + live updates

    private func run() async {
        var failures = 0, delay = 3.0
        while !Task.isCancelled {
            do {
                try await load()
                error = nil; failures = 0; delay = 3
                var r2 = try request("/eventstream/clip/v2")
                r2.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                r2.timeoutInterval = 300   // idle time between bytes: a dead stream (e.g. after sleep) is dropped and reopened
                let (bytes, _) = try await session.bytes(for: r2)
                // Read lines by hand: a line over 1 MB is dropped instead of buffered.
                var line = Data(), skipping = false
                for try await b in bytes {
                    if b != 10 {
                        if !skipping { line.append(b); if line.count > 1_000_000 { line = Data(); skipping = true } }
                        continue
                    }
                    if !skipping, let s = String(data: line, encoding: .utf8), s.hasPrefix("data:") { merge(String(s.dropFirst(5))) }
                    line = Data(); skipping = false
                }
            } catch {
                if Task.isCancelled || pinMismatch { return }
                self.error = String(localized: "Can't connect to the bridge: \(error.localizedDescription)")
                failures += 1
                if failures % 3 == 0 { await rediscover() }
            }
            try? await Task.sleep(for: .seconds(delay))
            delay = min(delay * 2, 60)
        }
    }

    /// The bridge may have a new IP (DHCP): look for it by id on the network and keep pin and key.
    private func rediscover() async {
        guard let c = cfg else { return }
        let found = await browseBridges()
        guard !Task.isCancelled, let b = found.first(where: { $0.id.caseInsensitiveCompare(c.id) == .orderedSame && $0.internalipaddress != c.ip }),
              let probe = bridgeURL(b.internalipaddress, "/api/config") else { return }
        // Bonjour is unauthenticated: only move if the new address serves the pinned certificate (no key is sent here).
        let s = URLSession(configuration: .ephemeral, delegate: Trust(ip: b.internalipaddress, pin: c.pin), delegateQueue: nil)
        defer { s.finishTasksAndInvalidate() }
        guard (try? await s.data(from: probe)) != nil, !Task.isCancelled else { return }
        UserDefaults.standard.set(b.internalipaddress, forKey: "bridgeIP")
        cfg?.ip = b.internalipaddress
        start()   // new session + Trust for the new IP; cancels this task
    }

    /// Full GET of everything we show. Our own recent writes are kept (their echo is still in flight).
    private func load() async throws {
        let r: [Room] = try await get("room"), l: [Light] = try await get("light")
        let g: [GroupedLight] = try await get("grouped_light"), s: [HueScene] = try await get("scene")
        let now = Date()
        func fresh(_ id: String) -> Bool { now.timeIntervalSince(touched[id] ?? .distantPast) > 0.6 }
        withAnimation(Hue.ease) {
            rooms = r.sorted { $0.metadata.name < $1.metadata.name }
            scenes = s
            lights = Dictionary(l.map { ($0.id, fresh($0.id) ? $0 : (lights[$0.id] ?? $0)) }, uniquingKeysWith: { a, _ in a })
            groups = Dictionary(g.map { ($0.id, fresh($0.id) ? $0 : (groups[$0.id] ?? $0)) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// Fresh GET: fallback for events we missed or ignored (scene recalls, popover opened, new rooms/scenes).
    func refresh() async {
        guard cfg != nil else { return }
        try? await load()
    }

    /// Debounced: events can come in bursts, so wait 1 s and refresh once.
    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task {
            try? await Task.sleep(for: .seconds(1))
            await refresh()
            refreshTask = nil
        }
    }

    /// S-curve used for changes coming from the bridge (scenes, other devices). Our own drags are never animated.
    static var ease: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.45)
    }

    private func merge(_ json: String) {
        struct Event: Decodable { var type: String; var data: [Lossy<Patch>] }
        guard let events = try? JSONDecoder().decode([Event].self, from: Data(json.utf8)) else { return }
        let patches = events.flatMap(\.data).compactMap(\.v)
        withAnimation(Hue.ease) { apply(patches) }
        if events.contains(where: { $0.type == "add" || $0.type == "delete" }) || patches.contains(where: { ["room", "zone", "scene"].contains($0.type) }) {
            scheduleRefresh()
        }
    }

    private func apply(_ patches: [Patch]) {
        for p in patches {
            if Date().timeIntervalSince(touched[p.id] ?? .distantPast) < 0.6 { continue }
            switch p.type {
            case "light":
                if let v = p.on { lights[p.id]?.on = v }
                if let v = p.dimming?.brightness { lights[p.id]?.dimming?.brightness = v }
                if let v = p.color?.xy { lights[p.id]?.color?.xy = v }
                if let m = p.color_temperature?.mirek { lights[p.id]?.color_temperature?.mirek = m }
                if let v = p.color_temperature?.mirek_valid { lights[p.id]?.color_temperature?.mirek_valid = v }
            case "grouped_light":
                if let v = p.on { groups[p.id]?.on = v }
                if let v = p.dimming?.brightness { groups[p.id]?.dimming = Dimming(brightness: v) }
            default: break
            }
        }
    }

    // MARK: Commands (optimistic update + throttled PUT)

    func lights(in room: Room) -> [Light] {
        let devices = Set(room.children.map(\.rid))
        return lights.values.filter { devices.contains($0.owner.rid) }.sorted { $0.metadata.name < $1.metadata.name }
    }

    private func touch(_ id: String) { touched[id] = Date() }

    func setOn(_ id: String, _ v: Bool) {
        lights[id]?.on.on = v; touch(id)
        put("light/\(id)", ["on": ["on": v]])
    }

    func setBrightness(_ ids: Set<String>, _ b: Double) {
        for id in ids where lights[id]?.dimming != nil {
            lights[id]?.dimming?.brightness = b; touch(id)
            put("light/\(id)", ["dimming": ["brightness": b]])
        }
    }

    func setXY(_ ids: Set<String>, _ xy: XY) {
        for id in ids where lights[id]?.color != nil {
            lights[id]?.color?.xy = xy
            lights[id]?.color_temperature?.mirek_valid = false
            touch(id)
            put("light/\(id)", ["on": ["on": true], "color": ["xy": ["x": xy.x, "y": xy.y]]])
        }
    }

    func setMirek(_ id: String, _ mirek: Int) {
        guard let ct = lights[id]?.color_temperature else { return }
        let m = min(max(Double(mirek), ct.lo), ct.hi).rounded()
        lights[id]?.color_temperature?.mirek = Int(m)
        lights[id]?.color_temperature?.mirek_valid = true
        touch(id)
        put("light/\(id)", ["color_temperature": ["mirek": Int(m)]])
    }

    func setGroupOn(_ g: String, _ v: Bool) {
        groups[g]?.on = On(on: v); touch(g)
        put("grouped_light/\(g)", ["on": ["on": v]])
    }

    func setGroupBrightness(_ g: String, _ b: Double) {
        groups[g]?.dimming = Dimming(brightness: b); touch(g)
        put("grouped_light/\(g)", ["dimming": ["brightness": b]])
    }

    // MARK: Scenes

    private func actions(_ room: Room) -> [[String: Any]] {
        lights(in: room).map { l in
            var a: [String: Any] = ["on": ["on": l.on.on]]
            if let b = l.dimming?.brightness { a["dimming"] = ["brightness": b] }
            if let m = l.color_temperature?.mirek, l.color_temperature?.mirek_valid != false {
                a["color_temperature"] = ["mirek": m]
            } else if let c = l.color {
                a["color"] = ["xy": ["x": c.xy.x, "y": c.xy.y]]
            }
            return ["target": ["rid": l.id, "rtype": "light"], "action": a]
        }
    }

    func recall(_ s: HueScene) {
        touched.removeAll()   // a recall changes lights we just touched: never swallow its events
        active[s.group.rid] = s.id
        send("scene/\(s.id)", "PUT", ["recall": ["action": "active"]], refresh: true)
    }
    /// Lights of the room that are on, and their average colour (warm fallback).
    func glow(_ room: Room) -> [RGB] { lights(in: room).filter(\.on.on).map(\.rgb) }
    func tint(_ room: Room) -> Color { (RGB.average(glow(room)) ?? RGB.warm).color }


    /// Trimmed, non-empty, at most 32 characters (the Hue limit).
    private func clean(_ name: String) -> String? {
        let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        return n.isEmpty ? nil : n
    }
    func createScene(_ name: String, in room: Room) {
        guard let name = clean(name) else { return }
        send("scene", "POST", ["type": "scene", "metadata": ["name": name],
                               "group": ["rid": room.id, "rtype": "room"], "actions": actions(room)], reloadScenes: true)
    }
    func updateScene(_ s: HueScene, in room: Room) { send("scene/\(s.id)", "PUT", ["actions": actions(room)], reloadScenes: true) }
    func renameScene(_ s: HueScene, _ name: String) { guard let name = clean(name) else { return }; send("scene/\(s.id)", "PUT", ["metadata": ["name": name]], reloadScenes: true) }
    func deleteScene(_ s: HueScene) { send("scene/\(s.id)", "DELETE", [:], reloadScenes: true) }
}
