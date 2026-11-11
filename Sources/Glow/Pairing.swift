import SwiftUI
import Network
import CryptoKit
import Security

struct BridgeConfig { var ip: String; var pin: String; var id: String; var key: String }

/// Bridge address and cert pin live in UserDefaults; the app key only in the Keychain.
enum BridgeStore {
    static let service = "io.github.samcok.glow"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func load() -> BridgeConfig? {
        let d = UserDefaults.standard
        guard let ip = d.string(forKey: "bridgeIP"), let pin = d.string(forKey: "bridgePin") else { return nil }
        let id = d.string(forKey: "bridgeID") ?? "bridge"
        var q = query(id)
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let key = String(data: data, encoding: .utf8) else { return nil }
        return BridgeConfig(ip: ip, pin: pin, id: id, key: key)
    }

    static func save(_ c: BridgeConfig) -> Bool {
        forget()
        var q = query(c.id)
        q[kSecValueData as String] = Data(c.key.utf8)
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { return false }
        let d = UserDefaults.standard
        d.set(c.ip, forKey: "bridgeIP"); d.set(c.pin, forKey: "bridgePin"); d.set(c.id, forKey: "bridgeID")
        return true
    }

    static func forget() {
        let d = UserDefaults.standard
        SecItemDelete(query(d.string(forKey: "bridgeID") ?? "bridge") as CFDictionary)
        for k in ["bridgeIP", "bridgePin", "bridgeID"] { d.removeObject(forKey: k) }
    }
}

/// An IPv4 address or a `.local` name: nothing else is ever put in a URL.
func validHost(_ s: String) -> Bool {
    (IPv4Address(s) != nil && !s.contains("%"))
        || s.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.local$"#, options: .regularExpression) != nil
}

func bridgeURL(_ host: String, _ path: String) -> URL? {
    guard validHost(host) else { return nil }
    var c = URLComponents()
    c.scheme = "https"; c.host = host; c.path = path
    return c.url
}

/// Accepts the bridge only if the host matches and the leaf certificate hash equals the stored pin.
/// With no pin (pairing) it trusts on first use and records the hash in `seen`.
final class Trust: NSObject, URLSessionDelegate, @unchecked Sendable {
    let ip: String
    let pin: String?
    let onMismatch: @Sendable () -> Void
    private(set) var seen: String?

    init(ip: String, pin: String?, onMismatch: @escaping @Sendable () -> Void = {}) {
        (self.ip, self.pin, self.onMismatch) = (ip, pin, onMismatch)
    }

    func urlSession(_ s: URLSession, didReceive c: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let p = c.protectionSpace
        guard p.authenticationMethod == NSURLAuthenticationMethodServerTrust, p.host == ip, let t = p.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(t) as? [SecCertificate])?.first
        else { return (.cancelAuthenticationChallenge, nil) }
        let hash = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        seen = hash
        if let pin, pin != hash { onMismatch(); return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: t))
    }
}

/// Finds Hue bridges with Bonjour (`_hue._tcp`) and resolves each to its IPv4 address.
func browseBridges(seconds: Double = 4) async -> [Pairing.Found] {
    await withCheckedContinuation { cont in
        let q = DispatchQueue(label: "glow.browse")
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_hue._tcp", domain: "local."), using: .tcp)
        let tcp = NWParameters.tcp
        (tcp.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        final class Acc: @unchecked Sendable { var found: [String: Pairing.Found] = [:]; var conns: [NWConnection] = [] }
        let acc = Acc()   // only touched on queue q
        browser.browseResultsChangedHandler = { results, _ in
            for r in results {
                let id: String
                if case .bonjour(let txt) = r.metadata, let b = txt["bridgeid"], !b.isEmpty { id = b }
                else if case .service(let name, _, _, _) = r.endpoint { id = name }
                else { id = "" }
                guard acc.found[id] == nil else { continue }
                let c = NWConnection(to: r.endpoint, using: tcp)
                c.stateUpdateHandler = { s in
                    guard case .ready = s else { return }
                    if case .hostPort(.ipv4(let a), _)? = c.currentPath?.remoteEndpoint {
                        let ip = String("\(a)".split(separator: "%")[0])   // drop the "%en0" interface suffix
                        if validHost(ip) { acc.found[id] = Pairing.Found(id: id, internalipaddress: ip) }
                    }
                    c.cancel()
                }
                acc.conns.append(c)
                c.start(queue: q)
            }
        }
        browser.start(queue: q)
        q.asyncAfter(deadline: .now() + seconds) {
            browser.cancel(); acc.conns.forEach { $0.cancel() }
            cont.resume(returning: Array(acc.found.values))
        }
    }
}

// MARK: - Pairing

@MainActor @Observable final class Pairing {
    struct Found: Identifiable, Decodable {
        var id: String
        var internalipaddress: String
    }
    var found: [Found] = []
    var searching = false
    var waiting = false          // link button step
    var succeeded = false        // key received: Setup plays its exit, then calls commit()
    @ObservationIgnored private var commitAction: (() -> Void)?
    var message: String?

    @ObservationIgnored private var task: Task<Void, Never>?
    private let hue: Hue
    init(hue: Hue) { self.hue = hue }

    /// Called by Setup once its exit animation is done: applies the config so Gate shows the app.
    func commit() { let a = commitAction; commitAction = nil; succeeded = false; a?() }

    func find() {
        if hue.demoSetup { found = [Found(id: "demo", internalipaddress: "192.168.1.2")]; return }
        searching = true; message = nil; found = []
        task = Task {
            defer { searching = false }
            // Bonjour first: local, instant, and not rate-limited like discovery.meethue.com.
            found = await browseBridges()
            if found.isEmpty, let url = URL(string: "https://discovery.meethue.com"),
               let (d, _) = try? await URLSession.shared.data(from: url),
               let list = try? JSONDecoder().decode([Lossy<Found>].self, from: d) {
                found = list.compactMap(\.v).filter { validHost($0.internalipaddress) }
            }
            if found.isEmpty && !Task.isCancelled {
                message = String(localized: "No bridge found on your network. Type its address below.")
            }
        }
    }

    func pair(host: String, id: String = "bridge") {
        guard validHost(host), let url = bridgeURL(host, "/api") else {
            message = String(localized: "That is not an IP address or a .local name."); return
        }
        cancel()
        waiting = true; message = nil
        if hue.demoSetup {   // fake link button press after 4 s, no network
            task = Task {
                defer { waiting = false }
                try? await Task.sleep(for: .seconds(4))
                if Task.isCancelled { return }
                commitAction = { [hue] in hue.finishDemoSetup() }
                succeeded = true
            }
            return
        }
        task = Task {
            defer { waiting = false }
            let trust = Trust(ip: host, pin: nil)
            let session = URLSession(configuration: .ephemeral, delegate: trust, delegateQueue: nil)
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 10
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["devicetype": "glow#mac", "generateclientkey": true])
            for _ in 0..<30 {   // every 2 s for 60 s
                do {
                    let (d, _) = try await session.data(for: req)
                    let items = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] ?? []
                    if let ok = items.first?["success"] as? [String: Any], let key = ok["username"] as? String, let pin = trust.seen {
                        if BridgeStore.save(BridgeConfig(ip: host, pin: pin, id: id, key: key)) {
                            commitAction = { [hue] in hue.cfg = BridgeStore.load(); hue.start() }
                            succeeded = true
                        } else { message = String(localized: "Could not save the key in the Keychain.") }
                        return
                    }
                    if let e = items.first?["error"] as? [String: Any], e["type"] as? Int != 101 {
                        message = String(localized: "The bridge refused the request."); return
                    }
                } catch {
                    if !Task.isCancelled { message = String(localized: "Can't reach the bridge at \(host).") }
                    return
                }
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
            }
            message = String(localized: "The link button was not pressed in time. Try again.")
        }
    }

    func cancel() { task?.cancel(); waiting = false; searching = false }
}

struct Setup: View {
    let pairing: Pairing
    var compact = false
    @StateObject private var host = Box("")
    @StateObject private var phase = Box(BridgePhase.hidden)
    @StateObject private var float = Box(false)
    @StateObject private var shadow = Box(0.0)   // shadow opacity follows the entrance/exit
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let p = pairing
        let size: CGFloat = compact ? 110 : 140
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            ZStack {
                Ellipse().fill(.black).frame(width: size * 0.8, height: size * 0.11).blur(radius: 7)
                    .scaleEffect(float.v ? 0.78 : 1).opacity((float.v ? 0.25 : 0.45) * shadow.v)
                    .offset(y: size * 0.5 + 18)
                BridgeArt(phase: phase.v, pulse: p.waiting, reduceMotion: reduceMotion)
                    .frame(width: size * BridgeArt.pad, height: size * BridgeArt.pad)
                    .frame(width: size, height: size)   // layout size; the 3D view overflows so scale 3 is not clipped
                    .offset(y: float.v ? -8 : 0).allowsHitTesting(false)
            }.frame(height: size + 40)
            Text(p.waiting || p.succeeded ? "Press the round button on your bridge" : "Set up your Hue Bridge")
                .font(.headline).multilineTextAlignment(.center).contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: p.waiting || p.succeeded)
            controls(p)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(20).frame(maxWidth: 380).frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if p.found.isEmpty && !p.searching && !p.waiting { p.find() }   // search without a click
            phase.v = .shown
            withAnimation(.easeInOut(duration: reduceMotion ? 0.3 : 2.0)) { shadow.v = 1 }
            if !reduceMotion { withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) { float.v = true } }
        }
        .task(id: p.succeeded) {
            guard p.succeeded else { return }
            phase.v = .exit
            withAnimation(.easeOut(duration: reduceMotion ? 0.3 : 0.4)) { shadow.v = 0 }
            try? await Task.sleep(for: .seconds(0.45))
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.3)) { p.commit() } }
        }
    }

    @ViewBuilder private func controls(_ p: Pairing) -> some View {
        VStack(spacing: 8) {
            if p.succeeded {
                EmptyView()
            } else if p.waiting {
                Button("Cancel") { p.cancel() }.buttonStyle(.plain).foregroundStyle(.secondary)
            } else {
                Button(p.searching ? "Searching…" : "Find my bridge") { p.find() }.controlSize(.small).buttonStyle(.glass).disabled(p.searching)
                ForEach(p.found) { b in
                    Button { p.pair(host: b.internalipaddress, id: b.id) } label: {
                        Label("Hue Bridge (\(b.internalipaddress))", systemImage: "wifi.router").frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.glass).controlSize(.small)
                }
                Text("Or type its address:").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("IP address or .local name", text: $host.v).textFieldStyle(.roundedBorder).controlSize(.small)
                        .onSubmit { p.pair(host: host.v.trimmingCharacters(in: .whitespaces)) }
                    Button("Connect") { p.pair(host: host.v.trimmingCharacters(in: .whitespaces)) }.controlSize(.small).disabled(host.v.isEmpty)
                }
            }
            if let m = p.message { Text(m).font(.caption).foregroundStyle(.red) }
        }.frame(maxWidth: 300)
    }
}

/// Shows setup or the certificate warning until a bridge is paired and trusted.
struct Gate<Content: View>: View {
    let hue: Hue
    var compact = false
    @ViewBuilder var content: () -> Content
    var body: some View {
        if hue.pinMismatch {
            VStack(spacing: 12) {
                Text("The bridge certificate changed. If you reset or replaced your bridge, pair again.")
                Button("Pair again") { hue.forget() }.buttonStyle(.glassProminent)
            }.padding(20).frame(maxWidth: 380).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !hue.configured { Setup(pairing: Shared.pairing, compact: compact) } else { content() }
    }
}
