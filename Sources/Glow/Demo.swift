import Foundation

// Fake data for screenshots: run with GLOW_DEMO=1. No network, no pairing; writes are no-ops.
extension Hue {
    func loadDemo() {
        func xy(_ h: Double, _ s: Double) -> XY { HueColor.xy(h: h, s: s) }
        func color(_ id: String, _ name: String, _ h: Double, _ s: Double, _ b: Double, on: Bool = true) -> Light {
            Light(id: id, owner: Ref(rid: "dev-" + id, rtype: "device"), metadata: Meta(name: name), on: On(on: on),
                  dimming: Dimming(brightness: b), color: LColor(xy: xy(h, s)),
                  color_temperature: CT(mirek: nil, mirek_valid: false, mirek_schema: .init(mirek_minimum: 153, mirek_maximum: 500)))
        }
        let floor = Light(id: "l3", owner: Ref(rid: "dev-l3", rtype: "device"), metadata: Meta(name: "Floor lamp"), on: On(on: true),
                          dimming: Dimming(brightness: 45), color: nil,
                          color_temperature: CT(mirek: 390, mirek_valid: true, mirek_schema: .init(mirek_minimum: 153, mirek_maximum: 454)))
        let all = [color("l1", "Desk lamp", 0.07, 0.75, 80), color("l2", "Shelf", 0.11, 0.5, 60), floor, color("l4", "Table lamp", 0.03, 0.8, 70)]
        lights = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func room(_ id: String, _ name: String, _ ls: [String]) -> Room {
            Room(id: id, metadata: Meta(name: name), children: ls.map { Ref(rid: "dev-" + $0, rtype: "device") },
                 services: [Ref(rid: "g-" + id, rtype: "grouped_light")])
        }
        rooms = [room("r1", "Bedroom", ["l1", "l2", "l3"]), room("r2", "Living room", ["l4"])]
        groups = ["g-r1": GroupedLight(id: "g-r1", on: On(on: true), dimming: Dimming(brightness: 62)),
                  "g-r2": GroupedLight(id: "g-r2", on: On(on: true), dimming: Dimming(brightness: 70))]
        func scene(_ id: String, _ name: String, _ room: String, _ cs: [(Double, Double)]) -> HueScene {
            HueScene(id: id, metadata: Meta(name: name), group: Ref(rid: room, rtype: "room"),
                     palette: .init(color: cs.map { .init(color: LColor(xy: xy($0.0, $0.1)), color_temperature: nil) }, color_temperature: nil))
        }
        scenes = [
            scene("s1", "Sunset", "r1", [(0.05, 0.85), (0.96, 0.6), (0.8, 0.5)]),
            scene("s2", "Reading", "r1", [(0.11, 0.35), (0.12, 0.25)]),
            scene("s3", "Nightlight", "r1", [(0.02, 0.9), (0.0, 0.7)]),
            scene("s4", "Ocean", "r1", [(0.55, 0.8), (0.5, 0.6), (0.62, 0.7)]),
            scene("s5", "Candle", "r1", [(0.08, 0.9), (0.06, 0.7)]),
            scene("s6", "Focus", "r1", [(0.55, 0.15), (0.14, 0.2)]),
            scene("s7", "Dawn", "r1", [(0.1, 0.6), (0.95, 0.35), (0.62, 0.3)]),
            scene("s8", "Relax", "r1", [(0.07, 0.6), (0.85, 0.4)]),
            scene("s9", "Bright", "r2", [(0.13, 0.2)]), scene("s10", "Movie", "r2", [(0.7, 0.6), (0.02, 0.7)]),
        ]
        active["r1"] = "s1"
    }
}
