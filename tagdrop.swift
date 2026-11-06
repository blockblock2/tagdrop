// TagDrop — send a .bin or .nfc (Flipper Zero) file from this Mac to a phone over Bluetooth or a USB
// cable. The phone opens the TagDrop website, types the code shown here, and
// writes the file to an NFC tag.
//
// One Swift file using only what's built into macOS (SwiftUI, CoreBluetooth,
// Network), so it runs with BananaPeel without installing anything.

import AppKit
import SwiftUI
import CoreBluetooth
import Network
import UniformTypeIdentifiers
import Combine

let SITE = "https://tagdropper.pages.dev"
let SITE_SHORT = "tagdropper.pages.dev"
let PORT: UInt16 = 8642
let MAX_SIZE = 64 * 1024
let CHUNK = 512 // biggest value one Bluetooth characteristic can hold

let INFO_C = CBUUID(string: "B4A70001-0000-4000-8000-000000000000")
let OFFSET_C = CBUUID(string: "B4A70002-0000-4000-8000-000000000000")
let DATA_C = CBUUID(string: "B4A70003-0000-4000-8000-000000000000")
let ALPHABET = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") // no 0/O or 1/I mix-ups

// MARK: - State shown in the window

final class Model: ObservableObject {
    @Published var fileName = ""
    @Published var fileData = Data()
    @Published var code = ""
    @Published var btText = "Starting Bluetooth…"
    @Published var btOK = false
    @Published var cableText = ""
    @Published var cableOK = false
    @Published var progress: Double = 0
    @Published var sentVia: String?
    @Published var error: String?
    @Published var hovering = false // window UI state lives here: @State needs a plugin
    @Published var copied = false   // that Command Line Tools' Swift doesn't have

    var infoJSON = Data()
    var hasFile: Bool { !fileData.isEmpty }
    var service: CBUUID {
        CBUUID(string: "B4A70000-0000-4000-8000-" + code.utf8.map { String(format: "%02X", $0) }.joined())
    }
    var onNewFile: (() -> Void)?

    @Published var mode = 0 // 0 = send a file, 1 = make a tag

    func load(_ url: URL) {
        error = nil
        guard let d = try? Data(contentsOf: url) else { error = "Couldn't open \(url.lastPathComponent)."; return }
        load(d, name: url.lastPathComponent)
    }

    func load(_ d: Data, name: String) {
        error = nil
        if d.isEmpty { error = "That file is empty."; return }
        if d.count > MAX_SIZE {
            error = "That file is \(d.count / 1024) KB. NFC tags hold a few KB at most, so TagDrop sends files up to \(MAX_SIZE / 1024) KB."
            return
        }
        fileName = name
        fileData = d
        newCode()
    }

    func newCode() {
        code = String((0..<6).map { _ in ALPHABET.randomElement()! })
        infoJSON = try! JSONSerialization.data(withJSONObject: ["name": fileName, "size": fileData.count, "code": code])
        progress = 0
        sentVia = nil
        onNewFile?()
    }

    func reset() {
        fileData = Data(); fileName = ""; code = ""; progress = 0; sentVia = nil; error = nil
        onNewFile?()
    }

    func sent(_ bytes: Int, via: String) {
        progress = Double(bytes) / Double(max(fileData.count, 1))
        if bytes >= fileData.count { sentVia = via; NSSound(named: "Glass")?.play() }
    }
}

// MARK: - Bluetooth (this Mac acts as the device the phone connects to)

final class Bluetooth: NSObject, CBPeripheralManagerDelegate {
    let m: Model
    var manager: CBPeripheralManager!
    var offset = 0

    init(_ m: Model) {
        self.m = m
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: nil)
    }

    // (Re)publish the service for the current file and code
    func publish() {
        guard manager.state == .poweredOn else { return }
        manager.stopAdvertising()
        manager.removeAllServices()
        offset = 0
        guard m.hasFile else { m.btText = "Bluetooth ready"; m.btOK = true; return }
        let info = CBMutableCharacteristic(type: INFO_C, properties: [.read], value: nil, permissions: [.readable])
        let off = CBMutableCharacteristic(type: OFFSET_C, properties: [.write], value: nil, permissions: [.writeable])
        let data = CBMutableCharacteristic(type: DATA_C, properties: [.read], value: nil, permissions: [.readable])
        let service = CBMutableService(type: m.service, primary: true)
        service.characteristics = [info, off, data]
        manager.add(service)
    }

    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        m.btOK = false
        switch p.state {
        case .poweredOn: publish()
        case .poweredOff: m.btText = "Bluetooth is off — turn it on in Control Center"
        case .unauthorized: m.btText = "Bluetooth not allowed — System Settings › Privacy & Security › Bluetooth"
        case .unsupported: m.btText = "This Mac can't do Bluetooth LE — use the cable"
        default: m.btText = "Starting Bluetooth…"
        }
    }

    func peripheralManager(_ p: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error { m.btText = "Bluetooth error: \(error.localizedDescription)"; return }
        p.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [service.uuid], CBAdvertisementDataLocalNameKey: "TagDrop"])
    }

    func peripheralManagerDidStartAdvertising(_ p: CBPeripheralManager, error: Error?) {
        if let error { m.btText = "Bluetooth error: \(error.localizedDescription)"; m.btOK = false }
        else { m.btText = "Bluetooth ready — waiting for the phone"; m.btOK = true }
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveRead req: CBATTRequest) {
        let source: Data
        switch req.characteristic.uuid {
        case INFO_C:
            source = m.infoJSON
            if req.offset == 0 { m.btText = "Phone connected — sending…" }
        case DATA_C:
            let end = min(offset + CHUNK, m.fileData.count)
            source = offset < end ? m.fileData.subdata(in: offset..<end) : Data()
            if req.offset == 0 { m.sent(end, via: "Bluetooth") }
        default:
            p.respond(to: req, withResult: .attributeNotFound)
            return
        }
        guard req.offset <= source.count else { p.respond(to: req, withResult: .invalidOffset); return }
        req.value = source.subdata(in: req.offset..<source.count)
        p.respond(to: req, withResult: .success)
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveWrite reqs: [CBATTRequest]) {
        for r in reqs where r.characteristic.uuid == OFFSET_C {
            guard let v = r.value, v.count == 4 else { p.respond(to: r, withResult: .invalidAttributeValueLength); return }
            let b = [UInt8](v)
            offset = Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16 | Int(b[3]) << 24
        }
        if let first = reqs.first { p.respond(to: first, withResult: .success) }
    }
}

// MARK: - Cable (tiny server on this Mac; `adb reverse` tunnels it over USB)

final class Cable {
    let m: Model
    var listener: NWListener?
    var timer: Timer?

    init(_ m: Model) {
        self.m = m
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback // only reachable from this Mac / the USB tunnel
        params.allowLocalEndpointReuse = true
        listener = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: PORT)!)
        listener?.newConnectionHandler = { [weak self] c in self?.handle(c) }
        listener?.start(queue: .main)

        if listener == nil { m.cableText = "Cable off — port \(PORT) is busy" }
        else if Cable.adbPath() == nil { m.cableText = "Cable needs Android tools: brew install android-platform-tools" }
        else {
            m.cableText = "Cable: plug in an Android phone (USB debugging on)"
            check()
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.check() }
        }
    }

    static func adbPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin/adb", "/usr/local/bin/adb",
                "\(home)/Library/Android/sdk/platform-tools/adb", "\(home)/platform-tools/adb"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    static func adb(_ args: [String]) -> Bool {
        guard let path = adbPath() else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return false }
        return p.terminationStatus == 0
    }

    // Keep trying the USB tunnel so plugging the phone in later still works
    func check() {
        DispatchQueue.global().async {
            let ok = Cable.adb(["reverse", "tcp:\(PORT)", "tcp:\(PORT)"])
            DispatchQueue.main.async {
                self.m.cableOK = ok
                self.m.cableText = ok ? "Cable: phone connected" : "Cable: plug in an Android phone (USB debugging on)"
            }
        }
    }

    func handle(_ c: NWConnection) {
        c.start(queue: .main)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [m] data, _, _, _ in
            guard let data, let text = String(data: data, encoding: .utf8),
                  let line = text.components(separatedBy: "\r\n").first else { c.cancel(); return }
            let parts = line.split(separator: " ")
            let method = parts.first.map(String.init) ?? ""
            let comps = URLComponents(string: parts.count > 1 ? String(parts[1]) : "/")
            let given = comps?.queryItems?.first(where: { $0.name == "code" })?.value?.uppercased()

            var status = "200 OK"
            var type = "application/json"
            var body = Data()
            if method == "OPTIONS" {
                status = "204 No Content"
            } else if !m.hasFile || given != m.code {
                status = "403 Forbidden"
                body = Data("{\"error\":\"wrong code\"}".utf8)
            } else if comps?.path == "/info" {
                body = m.infoJSON
            } else if comps?.path == "/file" {
                type = "application/octet-stream"
                body = m.fileData
                m.sent(m.fileData.count, via: "Cable")
            } else {
                status = "404 Not Found"
            }

            var head = "HTTP/1.1 \(status)\r\n"
            head += "Access-Control-Allow-Origin: *\r\n"
            head += "Access-Control-Allow-Methods: GET, OPTIONS\r\n"
            head += "Access-Control-Allow-Headers: *\r\n"
            head += "Access-Control-Allow-Private-Network: true\r\n"
            head += "Content-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
        }
    }
}

// MARK: - Make a tag (build NDEF records, wrap them like an NTAG dump)

struct BuildError: Error { let message: String }

enum RecKind: String, CaseIterable, Identifiable {
    case link = "Link", text = "Text", phone = "Phone call", email = "Email", sms = "Text message (SMS)",
         location = "Map location", wifi = "Wi-Fi network", contact = "Contact card",
         app = "Open an Android app", data = "Custom data"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .link: return "link"
        case .text: return "text.alignleft"
        case .phone: return "phone"
        case .email: return "envelope"
        case .sms: return "message"
        case .location: return "mappin.and.ellipse"
        case .wifi: return "wifi"
        case .contact: return "person.crop.circle"
        case .app: return "app.badge"
        case .data: return "curlybraces"
        }
    }
}

final class Rec: ObservableObject, Identifiable {
    let id = UUID()
    let kind: RecKind
    @Published var a = ""
    @Published var b = ""
    @Published var c = ""
    @Published var secure = 0 // Wi-Fi: 0 = WPA2/WPA3, 1 = open
    init(_ kind: RecKind) {
        self.kind = kind
        if kind == .data { b = "text/plain" }
    }
}

// (tnf, type, payload) for one NDEF record
typealias NdefRec = (tnf: UInt8, type: [UInt8], payload: [UInt8])

let URI_CODES: [(String, UInt8)] = [("https://www.", 2), ("http://www.", 1), ("https://", 4), ("http://", 3),
                                    ("tel:", 5), ("mailto:", 6)]

func uriRecord(_ uri: String) -> NdefRec {
    for (prefix, code) in URI_CODES where uri.lowercased().hasPrefix(prefix) {
        return (1, Array("U".utf8), [code] + Array(uri.dropFirst(prefix.count).utf8))
    }
    return (1, Array("U".utf8), [0] + Array(uri.utf8))
}

func esc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s }

func wifiPayload(ssid: String, key: String, open: Bool) -> [UInt8] {
    func attr(_ t: UInt16, _ v: [UInt8]) -> [UInt8] {
        [UInt8(t >> 8), UInt8(t & 0xFF), UInt8(v.count >> 8), UInt8(v.count & 0xFF)] + v
    }
    var cred = attr(0x1026, [1])                                  // network index
    cred += attr(0x1045, Array(ssid.utf8))                        // SSID
    cred += attr(0x1003, open ? [0x00, 0x01] : [0x00, 0x20])      // auth: open / WPA2-PSK
    cred += attr(0x100F, open ? [0x00, 0x01] : [0x00, 0x08])      // encryption: none / AES
    cred += attr(0x1027, Array((open ? "" : key).utf8))           // password
    cred += attr(0x1020, [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])    // any MAC
    return attr(0x100E, cred)
}

func encode(_ r: Rec) -> Result<NdefRec, BuildError> {
    let a = r.a.trimmingCharacters(in: .whitespacesAndNewlines)
    let b = r.b.trimmingCharacters(in: .whitespacesAndNewlines)
    let c = r.c.trimmingCharacters(in: .whitespacesAndNewlines)
    func need(_ ok: Bool, _ msg: String) -> BuildError? { ok ? nil : BuildError(message: msg) }
    switch r.kind {
    case .link:
        if let e = need(!a.isEmpty, "Type a link.") { return .failure(e) }
        return .success(uriRecord(a.contains(":") ? a : "https://" + a))
    case .text:
        if let e = need(!a.isEmpty, "Type some text.") { return .failure(e) }
        return .success((1, Array("T".utf8), [2] + Array("en".utf8) + Array(a.utf8)))
    case .phone:
        if let e = need(!a.isEmpty, "Type a phone number.") { return .failure(e) }
        return .success(uriRecord("tel:" + a.filter { !$0.isWhitespace }))
    case .email:
        if let e = need(a.contains("@"), "Type an email address.") { return .failure(e) }
        var q: [String] = []
        if !b.isEmpty { q.append("subject=" + esc(b)) }
        if !c.isEmpty { q.append("body=" + esc(c)) }
        return .success(uriRecord("mailto:" + a + (q.isEmpty ? "" : "?" + q.joined(separator: "&"))))
    case .sms:
        if let e = need(!a.isEmpty, "Type a phone number for the text message.") { return .failure(e) }
        return .success(uriRecord("sms:" + a.filter { !$0.isWhitespace } + (b.isEmpty ? "" : "?body=" + esc(b))))
    case .location:
        guard let lat = Double(a), let lon = Double(b), abs(lat) <= 90, abs(lon) <= 180 else {
            return .failure(BuildError(message: "Type a latitude and longitude, like 25.7617 and -80.1918."))
        }
        return .success(uriRecord("geo:\(lat),\(lon)"))
    case .wifi:
        if let e = need(!a.isEmpty, "Type the Wi-Fi name.") { return .failure(e) }
        if let e = need(r.secure == 1 || b.count >= 8, "Wi-Fi passwords are at least 8 characters.") { return .failure(e) }
        return .success((2, Array("application/vnd.wfa.wsc".utf8), wifiPayload(ssid: a, key: b, open: r.secure == 1)))
    case .contact:
        if let e = need(!a.isEmpty, "Type a name for the contact.") { return .failure(e) }
        var v = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:\(a)\r\n"
        if !b.isEmpty { v += "TEL:\(b)\r\n" }
        if !c.isEmpty { v += "EMAIL:\(c)\r\n" }
        v += "END:VCARD\r\n"
        return .success((2, Array("text/vcard".utf8), Array(v.utf8)))
    case .app:
        if let e = need(a.contains(".") && !a.contains(" "), "Type the app's package name, like com.spotify.music.") { return .failure(e) }
        return .success((4, Array("android.com:pkg".utf8), Array(a.utf8)))
    case .data:
        if let e = need(b.contains("/"), "Type a type like text/plain or application/json.") { return .failure(e) }
        if let e = need(!a.isEmpty, "Type the data.") { return .failure(e) }
        return .success((2, Array(b.utf8), Array(a.utf8)))
    }
}

func ndefMessage(_ recs: [NdefRec]) -> [UInt8] {
    var out: [UInt8] = []
    for (i, r) in recs.enumerated() {
        var h = r.tnf
        if i == 0 { h |= 0x80 }                 // message begin
        if i == recs.count - 1 { h |= 0x40 }    // message end
        let short = r.payload.count < 256
        if short { h |= 0x10 }
        out += [h, UInt8(r.type.count)]
        if short { out.append(UInt8(r.payload.count)) }
        else { let n = r.payload.count; out += [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] }
        out += r.type + r.payload
    }
    return out
}

// Same layout as an NTAG memory dump, so the phone page treats it like any other tag dump
func tagDump(_ msg: [UInt8]) -> Data {
    var tlv: [UInt8] = [0x03]
    if msg.count < 0xFF { tlv.append(UInt8(msg.count)) } else { tlv += [0xFF, UInt8(msg.count >> 8), UInt8(msg.count & 0xFF)] }
    tlv += msg + [0xFE]
    let areaSize = UInt8(min(255, (tlv.count + 7) / 8))
    var mem: [UInt8] = [0x04, 0, 0, 0, 0, 0, 0, 0, 0, 0x48, 0, 0, 0xE1, 0x10, areaSize, 0x00] + tlv
    while mem.count % 4 != 0 || mem.count < 48 { mem.append(0) }
    return Data(mem)
}

final class TagBuilder: ObservableObject {
    @Published var records: [Rec] = []
    private var watchers: [UUID: AnyCancellable] = [:]

    func add(_ k: RecKind) {
        let r = Rec(k)
        watchers[r.id] = r.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        records.append(r)
    }
    func remove(_ r: Rec) { records.removeAll { $0.id == r.id }; watchers[r.id] = nil }
    func move(_ r: Rec, by d: Int) {
        guard let i = records.firstIndex(where: { $0.id == r.id }), records.indices.contains(i + d) else { return }
        records.swapAt(i, i + d)
    }

    var messageSize: Int {
        let ok = records.compactMap { try? encode($0).get() }
        return ok.isEmpty ? 0 : ndefMessage(ok).count + 3
    }
    var sizeNote: String {
        let n = messageSize
        if n == 0 { return "" }
        let fit = n <= 137 ? "fits any NTAG tag" : n <= 496 ? "needs NTAG215 or bigger" : n <= 868 ? "needs NTAG216" : "too big for NTAG stickers"
        return "\(n) bytes — \(fit)"
    }

    func build() -> Result<Data, BuildError> {
        if records.isEmpty { return .failure(BuildError(message: "Add something for the tag to do first.")) }
        var out: [NdefRec] = []
        for (i, r) in records.enumerated() {
            switch encode(r) {
            case .success(let e): out.append(e)
            case .failure(let e): return .failure(BuildError(message: "\(i + 1). \(r.kind.rawValue): \(e.message)"))
            }
        }
        return .success(tagDump(ndefMessage(out)))
    }
}

struct Field: View {
    let label: String
    @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(.dim)
            TextField("", text: $text).textFieldStyle(.roundedBorder).font(.system(size: 13))
        }
    }
}

struct RecordCard: View {
    @ObservedObject var r: Rec
    let index: Int
    let remove: () -> Void
    let move: (Int) -> Void

    var body: some View {
        Card {
            HStack(spacing: 8) {
                Image(systemName: r.kind.icon).foregroundColor(.accent)
                Text("\(index + 1). \(r.kind.rawValue)").font(.system(size: 13, weight: .semibold)).foregroundColor(.ink)
                Spacer()
                Button { move(-1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).foregroundColor(.dim)
                Button { move(1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain).foregroundColor(.dim)
                Button(action: remove) { Image(systemName: "trash") }.buttonStyle(.plain).foregroundColor(.dim)
            }
            fields
        }
    }

    @ViewBuilder var fields: some View {
        switch r.kind {
        case .link: Field(label: "Link", text: $r.a)
        case .text: Field(label: "Text", text: $r.a)
        case .phone: Field(label: "Phone number", text: $r.a)
        case .email:
            Field(label: "To", text: $r.a)
            Field(label: "Subject (optional)", text: $r.b)
            Field(label: "Message (optional)", text: $r.c)
        case .sms:
            Field(label: "Phone number", text: $r.a)
            Field(label: "Message (optional)", text: $r.b)
        case .location:
            HStack {
                Field(label: "Latitude", text: $r.a)
                Field(label: "Longitude", text: $r.b)
            }
        case .wifi:
            Field(label: "Wi-Fi name", text: $r.a)
            Picker("", selection: $r.secure) {
                Text("Password").tag(0)
                Text("Open (no password)").tag(1)
            }.pickerStyle(.segmented).labelsHidden()
            if r.secure == 0 { Field(label: "Password", text: $r.b) }
        case .contact:
            Field(label: "Name", text: $r.a)
            Field(label: "Phone (optional)", text: $r.b)
            Field(label: "Email (optional)", text: $r.c)
        case .app:
            Field(label: "Android package name (e.g. com.spotify.music)", text: $r.a)
            Text("Opens the app (or its Play Store page) when an Android phone taps the tag. iPhones ignore this.")
                .font(.system(size: 11)).foregroundColor(.dim).fixedSize(horizontal: false, vertical: true)
        case .data:
            Field(label: "Type", text: $r.b)
            Field(label: "Data", text: $r.a)
        }
    }
}

struct BuilderView: View {
    @ObservedObject var b: TagBuilder
    let send: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if b.records.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "wave.3.right").font(.system(size: 36)).foregroundColor(.accent)
                    Text("What should the tag do?").font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundColor(.ink)
                    Text("Add a link, Wi-Fi, contact and more. A phone that taps the tag runs the first item.")
                        .font(.system(size: 12)).foregroundColor(.dim).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 30)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Array(b.records.enumerated()), id: \.element.id) { i, r in
                            RecordCard(r: r, index: i, remove: { b.remove(r) }, move: { b.move(r, by: $0) })
                        }
                    }
                }.frame(maxHeight: 380)
            }

            Menu {
                ForEach(RecKind.allCases) { k in Button(k.rawValue) { b.add(k) } }
            } label: {
                Label("Add to tag", systemImage: "plus")
            }.menuStyle(.borderlessButton).fixedSize().foregroundColor(.accent)

            HStack {
                Text(b.sizeNote).font(.system(size: 12)).foregroundColor(.dim)
                Spacer()
                Button(action: send) {
                    Text("Send to phone").font(.system(size: 14, weight: .semibold)).foregroundColor(Color(hex: 0x1A1405))
                        .padding(.horizontal, 20).padding(.vertical, 9)
                        .background(Capsule().fill(Color.accent))
                }.buttonStyle(.plain).disabled(b.records.isEmpty).opacity(b.records.isEmpty ? 0.4 : 1)
            }
        }
    }
}

// MARK: - Window

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    static let bg = Color(hex: 0x14110F), card = Color(hex: 0x1F1B18), line = Color(hex: 0x3A332D)
    static let ink = Color(hex: 0xF4EDE4), dim = Color(hex: 0xA39686), accent = Color(hex: 0xFFD23F)
    static let ok = Color(hex: 0x5FD38D), bad = Color(hex: 0xFF6B5B)
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color.card))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.line, lineWidth: 1))
    }
}

struct StatusRow: View {
    let ok: Bool, text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(ok ? Color.ok : Color.dim).frame(width: 9, height: 9).padding(.top, 4)
            Text(text).font(.system(size: 13)).foregroundColor(ok ? .ink : .dim).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ContentView: View {
    @ObservedObject var m: Model
    @ObservedObject var b: TagBuilder

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 0) {
                Text("Tag").foregroundColor(.ink)
                Text("Drop").foregroundColor(.accent)
            }.font(.system(size: 30, weight: .bold, design: .rounded))

            if m.hasFile { sending }
            else {
                Picker("", selection: $m.mode) {
                    Text("Send a file").tag(0)
                    Text("Make a tag").tag(1)
                }.pickerStyle(.segmented).labelsHidden()
                if m.mode == 0 { dropZone } else {
                    BuilderView(b: b, send: sendTag)
                }
            }

            if let e = m.error {
                Text(e).font(.system(size: 13)).foregroundColor(.bad).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(26)
        .frame(width: 460, height: 680)
        .background(Color.bg)
        .onDrop(of: [UTType.fileURL], isTargeted: $m.hovering) { providers in
            guard m.mode == 0, let item = providers.first else { return false }
            _ = item.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { m.load(url) } }
            }
            return true
        }
    }

    func sendTag() {
        m.error = nil
        switch b.build() {
        case .success(let dump): m.load(dump, name: "TagDrop tag.bin")
        case .failure(let e): m.error = e.message
        }
    }

    var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.arrow.down").font(.system(size: 42, weight: .medium)).foregroundColor(.accent)
            Text("Drop a .bin or .nfc file here").font(.system(size: 18, weight: .semibold, design: .rounded)).foregroundColor(.ink)
            Text("It goes to your phone over Bluetooth or USB,\nthen onto an NFC tag.")
                .font(.system(size: 13)).foregroundColor(.dim).multilineTextAlignment(.center)
            Button(action: choose) {
                Text("Choose File…").font(.system(size: 14, weight: .semibold)).foregroundColor(Color(hex: 0x1A1405))
                    .padding(.horizontal, 22).padding(.vertical, 10)
                    .background(Capsule().fill(Color.accent))
            }.buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, minHeight: 380)
        .background(RoundedRectangle(cornerRadius: 22).fill(m.hovering ? Color.card : Color.bg))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(m.hovering ? Color.accent : Color.line, style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
    }

    var sending: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                Text("ON YOUR PHONE, OPEN").font(.system(size: 11, weight: .semibold)).kerning(1.4).foregroundColor(.dim)
                HStack {
                    Text(SITE_SHORT).font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundColor(.accent)
                    Spacer()
                    Button(m.copied ? "Copied" : "Copy link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("\(SITE)/#\(m.code)", forType: .string)
                        m.copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { m.copied = false }
                    }.buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundColor(.dim)
                }
                Text("AND TYPE").font(.system(size: 11, weight: .semibold)).kerning(1.4).foregroundColor(.dim)
                HStack(spacing: 8) {
                    ForEach(Array(m.code.enumerated()), id: \.offset) { _, ch in
                        Text(String(ch))
                            .font(.system(size: 30, weight: .bold, design: .monospaced)).foregroundColor(.ink)
                            .frame(width: 50, height: 62)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.bg))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line, lineWidth: 2))
                    }
                }.textSelection(.enabled)
                Text("Android: Chrome  ·  iPhone: Bluefy").font(.system(size: 12)).foregroundColor(.dim)
            }

            Card {
                HStack {
                    Image(systemName: "doc").foregroundColor(.dim)
                    Text(m.fileName).font(.system(size: 14, weight: .medium)).foregroundColor(.ink).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("\(m.fileData.count) bytes").font(.system(size: 12)).foregroundColor(.dim)
                }
                ProgressView(value: m.progress).tint(m.sentVia == nil ? .accent : .ok)
                if let via = m.sentVia {
                    Text("Sent over \(via) ✓  The phone can write the tag now.")
                        .font(.system(size: 13, weight: .medium)).foregroundColor(.ok)
                }
                StatusRow(ok: m.btOK, text: m.btText)
                StatusRow(ok: m.cableOK, text: m.cableText)
            }

            HStack {
                Button(m.mode == 1 ? "Back to the tag" : "Send a different file") { m.reset() }
                    .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundColor(.dim)
                Spacer()
                Button("New code") { m.newCode() }
                    .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundColor(.dim)
            }
        }
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Pick the .bin or .nfc file to send"
        if panel.runModal() == .OK, let url = panel.url { m.load(url) }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { Cable.adb(["reverse", "--remove", "tcp:\(PORT)"]) }
}

let model = Model()
let builder = TagBuilder()
let bluetooth = Bluetooth(model)
let cable = Cable(model)
model.onNewFile = { bluetooth.publish() }
if CommandLine.arguments.count > 1 { model.load(URL(fileURLWithPath: CommandLine.arguments[1])) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)

// Menu so ⌘Q and ⌘W work
let mainMenu = NSMenu()
let appItem = NSMenuItem()
mainMenu.addItem(appItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
appMenu.addItem(withTitle: "Quit TagDrop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu
app.mainMenu = mainMenu

let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 680),
                      styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                      backing: .buffered, defer: false)
window.title = "TagDrop"
window.titlebarAppearsTransparent = true
window.backgroundColor = NSColor(red: 0x14 / 255, green: 0x11 / 255, blue: 0x0F / 255, alpha: 1)
window.appearance = NSAppearance(named: .darkAqua)
window.isReleasedWhenClosed = false
window.contentView = NSHostingView(rootView: ContentView(m: model, b: builder))
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

withExtendedLifetime((bluetooth, cable, delegate)) {
    app.run()
}
