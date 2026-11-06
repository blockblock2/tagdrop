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
    var url: URL?
    var hasFile: Bool { !fileData.isEmpty }
    var service: CBUUID {
        CBUUID(string: "B4A70000-0000-4000-8000-" + code.utf8.map { String(format: "%02X", $0) }.joined())
    }
    var onNewFile: (() -> Void)?

    func load(_ url: URL) {
        error = nil
        guard let d = try? Data(contentsOf: url) else { error = "Couldn't open \(url.lastPathComponent)."; return }
        if d.isEmpty { error = "That file is empty."; return }
        if d.count > MAX_SIZE {
            error = "That file is \(d.count / 1024) KB. NFC tags hold a few KB at most, so TagDrop sends files up to \(MAX_SIZE / 1024) KB."
            return
        }
        self.url = url
        fileName = url.lastPathComponent
        fileData = d
        code = String((0..<6).map { _ in ALPHABET.randomElement()! })
        infoJSON = try! JSONSerialization.data(withJSONObject: ["name": fileName, "size": d.count, "code": code])
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 0) {
                Text("Tag").foregroundColor(.ink)
                Text("Drop").foregroundColor(.accent)
            }.font(.system(size: 30, weight: .bold, design: .rounded))

            if m.hasFile { sending } else { dropZone }

            if let e = m.error {
                Text(e).font(.system(size: 13)).foregroundColor(.bad).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(26)
        .frame(width: 440, height: 600)
        .background(Color.bg)
        .onDrop(of: [UTType.fileURL], isTargeted: $m.hovering) { providers in
            guard let item = providers.first else { return false }
            _ = item.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { m.load(url) } }
            }
            return true
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
                Button("Send a different file") { m.reset() }
                    .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundColor(.dim)
                Spacer()
                Button("New code") { if let u = m.url { m.load(u) } }
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

let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 600),
                      styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                      backing: .buffered, defer: false)
window.title = "TagDrop"
window.titlebarAppearsTransparent = true
window.backgroundColor = NSColor(red: 0x14 / 255, green: 0x11 / 255, blue: 0x0F / 255, alpha: 1)
window.appearance = NSAppearance(named: .darkAqua)
window.isReleasedWhenClosed = false
window.contentView = NSHostingView(rootView: ContentView(m: model))
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

withExtendedLifetime((bluetooth, cable, delegate)) {
    app.run()
}
