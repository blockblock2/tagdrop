// TagDrop — send a .bin file from this Mac to an Android phone over
// Bluetooth or a USB cable. The phone opens the TagDrop website, types the
// code shown here, and writes the file to an NFC tag.
//
// Uses only frameworks built into macOS (CoreBluetooth + Network), so it runs
// with BananaPeel without installing anything.

import Foundation
import CoreBluetooth
import Network

let SITE = "https://tagdropper.pages.dev"
let PORT: UInt16 = 8642
let MAX_SIZE = 64 * 1024
let CHUNK = 512 // biggest value one Bluetooth characteristic can hold

// MARK: - Pick the file

func unescapeDragged(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.count >= 2, (s.hasPrefix("'") && s.hasSuffix("'")) || (s.hasPrefix("\"") && s.hasSuffix("\"")) {
        return String(s.dropFirst().dropLast())
    }
    var out = ""
    var escaping = false
    for ch in s {
        if escaping { out.append(ch); escaping = false }
        else if ch == "\\" { escaping = true }
        else { out.append(ch) }
    }
    s = out
    if s.hasPrefix("~") { s = NSString(string: s).expandingTildeInPath }
    return s
}

func pickFile() -> URL {
    if CommandLine.arguments.count > 1 {
        return URL(fileURLWithPath: unescapeDragged(CommandLine.arguments[1]))
    }
    print("Drag your .bin file into this window, then press Enter:")
    print("> ", terminator: "")
    fflush(stdout)
    guard let line = readLine(), !line.trimmingCharacters(in: .whitespaces).isEmpty else {
        print("No file given. Bye!")
        exit(1)
    }
    return URL(fileURLWithPath: unescapeDragged(line))
}

func loadFile(_ url: URL) -> Data {
    guard let d = try? Data(contentsOf: url) else {
        print("✖ Couldn't open \(url.path)")
        exit(1)
    }
    return d
}

let fileURL = pickFile()
let fileData = loadFile(fileURL)
if fileData.isEmpty { print("✖ That file is empty."); exit(1) }
if fileData.count > MAX_SIZE {
    print("✖ That file is \(fileData.count) bytes. NFC tags hold at most a few KB, so TagDrop only sends files up to \(MAX_SIZE / 1024) KB.")
    exit(1)
}

// MARK: - Code (e.g. ABC123), also baked into the Bluetooth service ID

let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") // no 0/O or 1/I mix-ups
let code = String((0..<6).map { _ in alphabet.randomElement()! })
let codeHex = code.utf8.map { String(format: "%02X", $0) }.joined()
let SERVICE = CBUUID(string: "B4A70000-0000-4000-8000-\(codeHex)")
let INFO_C = CBUUID(string: "B4A70001-0000-4000-8000-000000000000")
let OFFSET_C = CBUUID(string: "B4A70002-0000-4000-8000-000000000000")
let DATA_C = CBUUID(string: "B4A70003-0000-4000-8000-000000000000")

let infoJSON = try! JSONSerialization.data(withJSONObject: [
    "name": fileURL.lastPathComponent,
    "size": fileData.count,
    "code": code,
])

func progress(_ sent: Int, via: String) {
    let pct = Int(Double(sent) / Double(fileData.count) * 100)
    let bar = String(repeating: "█", count: pct / 5) + String(repeating: "░", count: 20 - pct / 5)
    print("\r   \(via): \(bar) \(pct)%", terminator: sent >= fileData.count ? "\n" : "")
    fflush(stdout)
    if sent >= fileData.count {
        print("   ✓ Sent! The phone can write it to a tag now. (Ctrl+C to quit, or leave open to send again.)")
    }
}

// MARK: - Bluetooth (this Mac acts as the device the phone connects to)

final class Bluetooth: NSObject, CBPeripheralManagerDelegate {
    var manager: CBPeripheralManager!
    var offset = 0

    override init() {
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: nil)
    }

    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        switch p.state {
        case .poweredOn:
            let info = CBMutableCharacteristic(type: INFO_C, properties: [.read], value: nil, permissions: [.readable])
            let off = CBMutableCharacteristic(type: OFFSET_C, properties: [.write], value: nil, permissions: [.writeable])
            let data = CBMutableCharacteristic(type: DATA_C, properties: [.read], value: nil, permissions: [.readable])
            let service = CBMutableService(type: SERVICE, primary: true)
            service.characteristics = [info, off, data]
            p.removeAllServices()
            p.add(service)
        case .poweredOff:
            print("   Bluetooth: off — turn it on in Control Center to use it.")
        case .unauthorized:
            print("   Bluetooth: not allowed — System Settings › Privacy & Security › Bluetooth, turn on Terminal, then run TagDrop again.")
        case .unsupported:
            print("   Bluetooth: this Mac can't do it. Use the cable instead.")
        default:
            break
        }
    }

    func peripheralManager(_ p: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error { print("   Bluetooth: couldn't start (\(error.localizedDescription))"); return }
        p.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [SERVICE],
            CBAdvertisementDataLocalNameKey: "TagDrop",
        ])
    }

    func peripheralManagerDidStartAdvertising(_ p: CBPeripheralManager, error: Error?) {
        if let error { print("   Bluetooth: couldn't start (\(error.localizedDescription))") }
        else { print("   Bluetooth: ready ✓") }
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveRead req: CBATTRequest) {
        let source: Data
        switch req.characteristic.uuid {
        case INFO_C:
            source = infoJSON
        case DATA_C:
            let end = min(offset + CHUNK, fileData.count)
            source = offset < end ? fileData.subdata(in: offset..<end) : Data()
            if req.offset == 0 { progress(end, via: "Bluetooth") }
        default:
            p.respond(to: req, withResult: .attributeNotFound)
            return
        }
        guard req.offset <= source.count else {
            p.respond(to: req, withResult: .invalidOffset)
            return
        }
        req.value = source.subdata(in: req.offset..<source.count)
        p.respond(to: req, withResult: .success)
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveWrite reqs: [CBATTRequest]) {
        for r in reqs where r.characteristic.uuid == OFFSET_C {
            guard let v = r.value, v.count == 4 else {
                p.respond(to: r, withResult: .invalidAttributeValueLength)
                return
            }
            let b = [UInt8](v)
            offset = Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16 | Int(b[3]) << 24
        }
        if let first = reqs.first { p.respond(to: first, withResult: .success) }
    }
}

// MARK: - Cable (tiny server on this Mac; `adb reverse` tunnels it over USB)

final class Cable {
    var listener: NWListener?

    init() {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback // only reachable from this Mac / the USB tunnel
        params.allowLocalEndpointReuse = true
        do {
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: PORT)!)
        } catch {
            print("   Cable: port \(PORT) is busy, cable mode is off.")
            return
        }
        listener?.newConnectionHandler = { [weak self] c in self?.handle(c) }
        listener?.start(queue: .main)
    }

    func handle(_ c: NWConnection) {
        c.start(queue: .main)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
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
            } else if given != code {
                status = "403 Forbidden"
                body = Data("{\"error\":\"wrong code\"}".utf8)
            } else if comps?.path == "/info" {
                body = infoJSON
            } else if comps?.path == "/file" {
                type = "application/octet-stream"
                body = fileData
                progress(fileData.count, via: "Cable")
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

func findADB() -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let spots = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb",
                 "\(home)/Library/Android/sdk/platform-tools/adb", "\(home)/platform-tools/adb"]
    return spots.first { FileManager.default.isExecutableFile(atPath: $0) }
}

@discardableResult
func adb(_ path: String, _ args: [String]) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit() } catch { return false }
    return p.terminationStatus == 0
}

// Keep trying the USB tunnel so plugging the phone in later still works.
var tunnelUp = false
func checkCable() {
    guard let path = findADB() else { return }
    let ok = adb(path, ["reverse", "tcp:\(PORT)", "tcp:\(PORT)"])
    if ok && !tunnelUp { print("   Cable: phone connected ✓") }
    tunnelUp = ok
}

// MARK: - Go

print("""

   📲  TagDrop

   File:  \(fileURL.lastPathComponent) (\(fileData.count) bytes)

   On your phone, open  \(SITE)
   and type this code:

          ┌─────────────┐
          │   \(code.map(String.init).joined(separator: " "))   │
          └─────────────┘

""")

let bluetooth = Bluetooth()
let cable = Cable()
if findADB() == nil {
    print("   Cable: needs Android platform-tools (brew install android-platform-tools)")
    print("          and USB debugging on the phone. Bluetooth works without it.")
} else {
    print("   Cable: plug the phone in with USB debugging on (or just use Bluetooth).")
    checkCable()
    Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in checkCable() }
}

// Ctrl+C: remove the USB tunnel, then quit
signal(SIGINT, SIG_IGN)
let stopSignal = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
stopSignal.setEventHandler {
    if let path = findADB() { adb(path, ["reverse", "--remove", "tcp:\(PORT)"]) }
    print("\n   Bye!")
    exit(0)
}
stopSignal.resume()

withExtendedLifetime((bluetooth, cable, stopSignal)) {
    RunLoop.main.run()
}
