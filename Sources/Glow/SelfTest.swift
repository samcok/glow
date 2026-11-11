import Foundation

/// Release-safe checks (assert is stripped in release). Run with `./build.sh --test`; exits non-zero on failure.
func selfTest() {
    var failed = 0
    func check(_ ok: Bool, _ what: String) { if !ok { failed += 1; print("FAIL: \(what)") } }

    for h in stride(from: 0.0, to: 1, by: 1.0 / 12) {
        for s in [0.4, 0.7, 1.0] {
            let r = HueColor.hs(HueColor.xy(h: h, s: s)), dh = abs(r.h - h)
            check(min(dh, 1 - dh) < 0.01 && abs(r.s - s) < 0.01, "xy round-trip h=\(h) s=\(s): \(r)")
        }
    }
    for ok in ["192.168.1.63", "foo.local"] { check(validHost(ok), "validHost accepts \(ok)") }
    for bad in ["a b", "http://x", "1.2.3.4%en0", ""] { check(!validHost(bad), "validHost rejects \(bad)") }
    for m in [153, 250, 326, 500] {
        var ct = CT(); ct.mirek = m
        check(ct.mirek(t: ct.t) == m, "mirek round-trip \(m)")
    }
    var cool = CT(); cool.mirek = 153
    var warm = CT(); warm.mirek = 500
    check(cool.t == 0 && warm.t == 1, "CT scale ends")
    let json = #"{"data":[{"id":"a","on":{"on":true}},{"bad":1},{"id":"b","on":{"on":false}}]}"#
    struct Item: Decodable { var id: String }
    struct R: Decodable { var data: [Lossy<Item>] }
    let ids = (try? JSONDecoder().decode(R.self, from: Data(json.utf8)))?.data.compactMap(\.v?.id)
    check(ids == ["a", "b"], "Lossy skips one bad item: \(String(describing: ids))")

    print(failed == 0 ? "selftest OK" : "selftest FAILED: \(failed)")
    exit(failed == 0 ? 0 : 1)
}
