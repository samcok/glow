import SwiftUI
import SceneKit

enum BridgePhase { case hidden, shown, exit }

/// Original 3D hub (SceneKit, built in code): rounded white body, recessed round button, ring that glows blue.
/// The view is 3.2x the art size so the scale-3 entrance is not clipped; lay it out with a `size` frame and no clipping.
struct BridgeArt: NSViewRepresentable {
    var phase: BridgePhase
    var pulse: Bool            // waiting for the link button: ring pulses; otherwise lit softly
    var reduceMotion: Bool

    static let pad: CGFloat = 3.2
    static func ease(_ x: Double) -> Double {   // cubic-bezier(0.65, 0, 0.35, 1), same curve as CAMediaTimingFunction
        let (x1, x2, y1, y2) = (0.65, 0.35, 0.0, 1.0)
        func b(_ t: Double, _ a: Double, _ c: Double) -> Double { 3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * c + t * t * t }
        var lo = 0.0, hi = 1.0
        for _ in 0..<24 { let m = (lo + hi) / 2; if b(m, x1, x2) < x { lo = m } else { hi = m } }
        return b((lo + hi) / 2, y1, y2)
    }

    final class Coordinator {
        let pivot = SCNNode(), ring = SCNNode(), halo = SCNNode()
        let glowNode = SCNNode()   // runs the pulse action
        var phase = BridgePhase.hidden
        var pulse: Bool?
        func setGlow(_ g: Double) {
            ring.geometry?.firstMaterial?.emission.intensity = CGFloat(g * 1.6)
            halo.opacity = CGFloat(g * 0.85)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let c = context.coordinator
        let v = SCNView()
        let scene = SCNScene()
        v.scene = scene
        v.backgroundColor = .clear
        v.antialiasingMode = .multisampling4X
        v.allowsCameraControl = false
        v.preferredFramesPerSecond = 60
        v.rendersContinuously = true
        v.setAccessibilityLabel("Hue Bridge")
        v.layer?.isOpaque = false

        let cam = SCNNode(); cam.camera = SCNCamera(); cam.camera?.fieldOfView = 30
        cam.position = SCNVector3(0, 0, 8.36); scene.rootNode.addChildNode(cam)
        func light(_ t: SCNLight.LightType, _ i: CGFloat, _ pos: SCNVector3? = nil) {
            let n = SCNNode(); n.light = SCNLight(); n.light?.type = t; n.light?.intensity = i
            if let p = pos { n.position = p; n.look(at: SCNVector3Zero) }
            scene.rootNode.addChildNode(n)
        }
        light(.ambient, 420)
        light(.directional, 650, SCNVector3(-3, 5, 8))
        light(.directional, 180, SCNVector3(5, -2, 6))

        func mat(_ w: CGFloat, rough: CGFloat = 0.55) -> SCNMaterial {
            let m = SCNMaterial(); m.lightingModel = .physicallyBased
            m.diffuse.contents = NSColor(white: w, alpha: 1); m.roughness.contents = rough; m.metalness.contents = 0; return m
        }
        let path = NSBezierPath(roundedRect: NSRect(x: -0.7, y: -0.7, width: 1.4, height: 1.4), xRadius: 0.39, yRadius: 0.39)
        path.flatness = 0.002   // default is coarse: corners come out as chamfered octagons
        let shape = SCNShape(path: path, extrusionDepth: 0.35)
        shape.chamferRadius = 0.07; shape.chamferMode = .both
        let front = mat(0.88), side = mat(0.62)
        shape.materials = [front, front, side]   // front, back, extruded side
        let body = SCNNode(geometry: shape)
        let (mn, mx) = body.boundingBox
        body.pivot = SCNMatrix4MakeTranslation((mn.x + mx.x) / 2, (mn.y + mx.y) / 2, (mn.z + mx.z) / 2)
        let zf = CGFloat(mx.z - mn.z) / 2   // front face z
        c.pivot.addChildNode(body)

        func disc(_ r: CGFloat, _ h: CGFloat, _ m: SCNMaterial, _ z: CGFloat) -> SCNNode {
            let n = SCNNode(geometry: SCNCylinder(radius: r, height: h)); n.geometry?.firstMaterial = m
            n.eulerAngles.x = .pi / 2; n.position = SCNVector3(0, 0, z); return n
        }
        c.pivot.addChildNode(disc(0.36, 0.012, mat(0.55), zf + 0.004))      // dark well: reads as recessed
        c.pivot.addChildNode(disc(0.31, 0.02, mat(0.97, rough: 0.35), zf + 0.01))

        let tube = SCNTube(innerRadius: 0.40, outerRadius: 0.45, height: 0.03)
        let rm = mat(0.8); rm.diffuse.contents = NSColor(red: 0.45, green: 0.62, blue: 0.95, alpha: 1); rm.emission.contents = NSColor(red: 0x4F / 255, green: 0x9B / 255, blue: 1, alpha: 1)
        tube.firstMaterial = rm
        c.ring.geometry = tube; c.ring.eulerAngles.x = .pi / 2; c.ring.position = SCNVector3(0, 0, zf + 0.008)
        c.pivot.addChildNode(c.ring)

        // bloom: radial gradient sprite, soft blue
        let img = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { r in
            NSGradient(colors: [NSColor(red: 0.2, green: 0.4, blue: 0.75, alpha: 1), NSColor.black],
                       atLocations: [0.15, 0.6], colorSpace: .sRGB)?.draw(in: r, relativeCenterPosition: .zero); return true
        }
        let plane = SCNPlane(width: 1.2, height: 1.2)
        let hm = SCNMaterial(); hm.lightingModel = .constant; hm.diffuse.contents = img; hm.blendMode = .add; hm.writesToDepthBuffer = false
        plane.firstMaterial = hm
        c.halo.geometry = plane; c.halo.position = SCNVector3(0, 0, zf + 0.02); c.halo.renderingOrder = 10
        c.pivot.addChildNode(c.halo)

        c.pivot.scale = SCNVector3(3, 3, 3); c.pivot.eulerAngles.y = -3 * .pi
        // Node opacity < 1 makes SceneKit draw the model see-through, so the 3D motion keeps it fully opaque; only Reduce Motion fades.
        c.pivot.opacity = reduceMotion ? 0 : 1
        if reduceMotion { c.pivot.scale = SCNVector3(1, 1, 1); c.pivot.eulerAngles.y = 0 }
        scene.rootNode.addChildNode(c.pivot); scene.rootNode.addChildNode(c.glowNode)
        c.setGlow(0.35)
        return v
    }

    func updateNSView(_ v: SCNView, context: Context) {
        let c = context.coordinator
        if c.pulse != pulse {
            c.pulse = pulse
            c.glowNode.removeAllActions()
            if pulse && !reduceMotion {   // 0.4...1 and back, 1.2 s each way
                c.glowNode.runAction(.repeatForever(.customAction(duration: 2.4) { _, t in c.setGlow(0.7 - 0.3 * cos(Double(t) / 2.4 * 2 * .pi)) }))
            } else { c.setGlow(pulse ? 0.7 : 0.35) }
        }
        guard c.phase != phase else { return }
        c.phase = phase
        let n = c.pivot
        let (s0, r0, o0) = (Double(n.scale.x), Double(n.eulerAngles.y), Double(n.opacity))
        let (s1, r1, o1): (Double, Double, Double)
        switch phase {
        case .hidden: return
        case .shown: (s1, r1, o1) = (1, 0, 1)
        case .exit: (s1, r1, o1) = (3, 3 * .pi, 0)
        }
        let d: Double = reduceMotion ? 0.3 : (phase == .shown ? 2.0 : 0.4)
        n.removeAllActions()
        n.runAction(.customAction(duration: d) { node, t in
            let k = Double(t) / d
            if reduceMotion { node.opacity = CGFloat(o0 + (o1 - o0) * k); return }
            let e = Self.ease(k)
            let s = s0 + (s1 - s0) * e
            node.scale = SCNVector3(s, s, s); node.eulerAngles.y = CGFloat(r0 + (r1 - r0) * e)
        })
    }
}
