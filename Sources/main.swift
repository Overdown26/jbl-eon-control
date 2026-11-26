import SwiftUI
import CoreBluetooth
import Combine

// MARK: - EONKit (protocolo)
enum EONGATT {
    static let service = "FDDF"
    static let mixer = "40E2B030-1A42-33AA-AD33-D11332244338"
    static let deviceInformation = "180A"
    static let firmwareRevision = "2A26"
}

enum EONModel: String, CaseIterable {
    case eon710, eon712, eon715
    static func from(name: String?) -> EONModel? {
        guard let n = name?.lowercased() else { return nil }
        return allCases.first { n.contains($0.rawValue.replacingOccurrences(of: "eon", with: "eon")) }
    }
    var title: String { "JBL " + rawValue.uppercased() }
}

enum EONChannel: Int, CaseIterable, Identifiable {
    case master = 0, ch1 = 1, ch2 = 2
    var id: Int { rawValue }
    var label: String { self == .master ? "Maestro" : "Canal \(rawValue)" }
}

enum VolumeMap {
    static let master = [-100,-80,-65,-55,-50,-45,-40,-37,-35,-33,-31,-29,-27,-25,-23,-21,-19,-17,-15,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1,0]
    static let channel = [-100,-80,-70,-66,-64,-62,-60,-58,-56,-54,-52,-50,-48,-46,-44,-42,-40,-38,-36,-34,-32,-30,-28,-26,-24,-22,-20,-18,-16,-14,-12,-10,-8,-6,-4,-2,0]
    static func table(_ c: EONChannel) -> [Int] { c == .master ? master : channel }
    static func range(_ c: EONChannel) -> ClosedRange<Int> { 0...(table(c).count - 1) }
    static func dB(_ c: EONChannel, _ i: Int) -> Int? { let t = table(c); return t.indices.contains(i) ? t[i] : nil }
    static func text(_ c: EONChannel, _ i: Int) -> String {
        guard let d = dB(c, i) else { return "—" }
        return d <= -100 ? "−∞ dB" : "\(d < 0 ? "−" : "")\(abs(d)) dB"
    }
}

struct MixerState: Equatable {
    var volume: [EONChannel: Int] = [:]
    var mute: [EONChannel: Bool] = [:]
    /// Trama de 4 bytes [selector(0 maestro,1 c1,2 c2,3 c1+c2), mute(1=silenciado), vol, vol2]
    @discardableResult mutating func apply(_ data: Data) -> Bool {
        let b = [UInt8](data)
        if b.count >= 6 {   // estado completo: [vol M, vol C1, vol C2, mute M, mute C1, mute C2]
            for (i, c) in EONChannel.allCases.enumerated() {
                volume[c] = min(Int(b[i]), VolumeMap.range(c).upperBound); mute[c] = b[3 + i] != 0
            }
            return true
        }
        guard b.count >= 4, b[0] <= 3 else { return false }
        let m = b[1] == 1
        func set(_ c: EONChannel, _ v: UInt8) { volume[c] = min(Int(v), VolumeMap.range(c).upperBound); mute[c] = m }
        switch b[0] {
        case 0: set(.master, b[2])
        case 1: set(.ch1, b[2])
        case 2: set(.ch2, b[2])
        default: set(.ch1, b[2]); set(.ch2, b[3])
        }
        return true
    }
}

/// Salida XLR pass-thru. Lectura de 10 bytes; escritura [item, valor(2, BE)]
struct XLRState: Equatable {
    var enabled = false, preset = 0
    var hpf = 20, lpf = 20000          // Hz (el protocolo usa unidades de 10 Hz)
    var level = 0                      // índice 0...87 (tabla en XLRMap)
    var spkDelay = 0, outDelay = 0     // 0...100 (pasos del protocolo)
    var post = false
    init() {}
    init?(_ b: [UInt8]) {
        guard b.count >= 10 else { return nil }
        enabled = b[0] != 0; preset = Int(b[1])
        hpf = (Int(b[2]) << 8 | Int(b[3])) * 10; lpf = (Int(b[4]) << 8 | Int(b[5])) * 10
        level = min(Int(b[6]), 87); spkDelay = Int(b[7]); outDelay = Int(b[8]); post = b[9] != 0
    }
    mutating func set(item: Int, value v: Int) {
        switch item {
        case 0: enabled = v != 0; case 1: preset = v
        case 2: hpf = v * 10; case 3: lpf = v * 10
        case 4: level = min(v, 87); case 5: spkDelay = v; case 6: outDelay = v; case 7: post = v != 0
        default: break }
    }
}
enum XLRMap {
    static func dB(_ i: Int) -> Int { i == 0 ? -100 : (i == 1 ? -80 : i - 81) }
    static func text(_ i: Int) -> String { let d = dB(i); return d <= -100 ? "−∞ dB" : "\(d < 0 ? "−" : (d > 0 ? "+" : ""))\(abs(d)) dB" }
}

struct EQBand: Equatable {
    var gain: Double; var freq: Int; var q: Double      // dB (±9), Hz, Q
    static let gainRange = -9.0...9.0
    init(gain: Double, freq: Int, q: Double) { self.gain = gain; self.freq = freq; self.q = q }
    /// 5 bytes: [ganancia(0..180 = -9..+9 dB en 0.1), freq(2, BE), q(2, BE, 0.01)]
    init(_ b: [UInt8]) { gain = (Double(b[0]) - 90) / 10; freq = Int(b[1]) << 8 | Int(b[2]); q = Double(Int(b[3]) << 8 | Int(b[4])) / 100 }
    var gainByte: UInt8 { UInt8(max(0, min(180, Int((gain * 10).rounded()) + 90))) }
}

enum EONGATT2 {
    static let eqTune = "40E2B030-1A42-33AA-AD33-D22441166546"
    static let eqStatus = "40E2B030-1A42-33AA-AD33-D22441166342"
    static let eqPreset = "40E2B030-1A42-33AA-AD33-D22441188636"
    static let bass = "40E2B030-1A42-33AA-AD33-D66666622643"
    static let gain = "40E2B030-1A42-33AA-AD33-D22441133120"
    static let locate = "40E2B030-1A42-33AA-AD33-D224413021BA"
    static let lock = "40E2B030-1A42-33AA-AD11-D22222111111"
    static let xlr = "40E2B030-1A42-33AA-AD55-D66666622135"
    static let all = [EONGATT.mixer, eqTune, eqStatus, eqPreset, bass, gain, locate, lock, xlr]
}
let eqPresetNames = ["Custom", "Flat", "Speech", "DJ", "Cafe", "KTV", "Monitor", "On Wall"]

enum MixerCommand: Hashable {
    case volume(EONChannel, Int), mute(EONChannel, Bool)
    case eqBand(Int, Double, Int, Double), eqEnable(Bool), eqPreset(Int), bass(Bool)
    case gain(Int, Int), lock(Bool), locate
    case xlr(Int, Int)      // item 0...7, valor
    var charUUID: String {
        switch self {
        case .volume, .mute: return EONGATT.mixer
        case .eqBand: return EONGATT2.eqTune
        case .eqEnable: return EONGATT2.eqStatus
        case .eqPreset: return EONGATT2.eqPreset
        case .bass: return EONGATT2.bass
        case .gain: return EONGATT2.gain
        case .lock: return EONGATT2.lock
        case .locate: return EONGATT2.locate
        case .xlr: return EONGATT2.xlr
        }
    }
    var key: String {
        switch self {
        case .volume(let c,_): return "v\(c.rawValue)"; case .mute(let c,_): return "m\(c.rawValue)"
        case .eqBand(let i,_,_,_): return "eq\(i)"; case .eqEnable: return "eqen"; case .eqPreset: return "eqpre"; case .bass: return "bass"
        case .gain(let c,_): return "g\(c)"; case .lock: return "lock"; case .locate: return "loc"; case .xlr(let i,_): return "x\(i)"
        }
    }
    func encode() -> Data {
        switch self {
        case .volume(let c, let i): return Data([UInt8(c.rawValue), 0, UInt8(max(0, min(i, VolumeMap.range(c).upperBound))), 0])
        case .mute(let c, let m): return Data([UInt8(c.rawValue), 1, m ? 1 : 0, 0])
        case .eqBand(let i, let g, let f, let q):
            let b = EQBand(gain: g, freq: f, q: q); let fq = max(20, min(20000, f)); let qq = max(1, min(1600, Int((q * 100).rounded())))
            return Data([UInt8(i), b.gainByte, UInt8(fq >> 8), UInt8(fq & 255), UInt8(qq >> 8), UInt8(qq & 255)])
        case .eqEnable(let on): return Data([on ? 1 : 0])
        case .eqPreset(let p): return Data([UInt8(max(0, min(7, p)))])
        case .bass(let on): return Data([on ? 1 : 0])
        case .gain(let c, let g): return Data([UInt8(c), UInt8(max(0, min(18, g)))])   // g: 0..18 = 0..36 dB
        case .lock(let on): return Data([on ? 1 : 0])
        case .locate: return Data([4])
        case .xlr(let i, let v): return Data([UInt8(i), UInt8((v >> 8) & 255), UInt8(v & 255)])
        }
    }
}

extension Data { var hex: String { map { String(format: "%02x", $0) }.joined(separator: " ") } }

// MARK: - Log
enum AppLog {
    static let url: URL = {
        let d = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs")
        return d.appendingPathComponent("JBLEONControl.log")
    }()
    static let fmt = ISO8601DateFormatter()
    static func write(_ s: String) {
        let line = "\(fmt.string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }
}

// MARK: - Bluetooth
enum LinkStatus: Equatable { case searching, connecting, syncing, connected, reconnecting, idle }

@MainActor final class SpeakerVM: NSObject, ObservableObject, Identifiable, CBPeripheralDelegate {
    let id: UUID; let name: String
    let model: EONModel?
    let peripheral: CBPeripheral
    @Published var state: MixerState?
    @Published var status: LinkStatus = .connecting
    @Published var firmware: String?
    @Published var lastError: String?
    @Published var editing: Set<EONChannel> = []
    var mixerChar: CBCharacteristic?
    var chars: [String: CBCharacteristic] = [:]
    @Published var eqEnabled: Bool?
    @Published var eqPresetIdx: Int?
    @Published var bass: Bool?
    @Published var bands: [EQBand] = []
    @Published var gains: [Int: Int] = [:]
    @Published var locked: Bool?
    @Published var editingGain: Int?
    @Published var xlr: XLRState?
    @Published var editingXLR: Int?
    @Published var editingBand: Int?
    var pending: [String: MixerCommand] = [:]; var order: [String] = []
    var inFlight: String?
    var keepAlive: Timer?
    weak var central: Link?

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral; self.id = peripheral.identifier
        self.name = peripheral.name ?? "JBL EON"
        self.model = EONModel.from(name: peripheral.name)
        super.init(); peripheral.delegate = self
    }
    var title: String { model?.title ?? name }

    func send(_ cmd: MixerCommand) {
        if state == nil && cmd.charUUID == EONGATT.mixer { return }
        switch cmd {
        case .volume(let c, let v): state?.volume[c] = v
        case .mute(let c, let m): state?.mute[c] = m
        case .eqBand(let i, let g, let f, let q): if bands.indices.contains(i) { bands[i] = EQBand(gain: g, freq: f, q: q) }
        case .eqEnable(let on): eqEnabled = on
        case .eqPreset(let p): eqPresetIdx = p
        case .bass(let on): bass = on
        case .gain(let c, let g): gains[c] = g
        case .lock(let on): locked = on
        case .locate: break
        case .xlr(let i, let v): if xlr != nil { xlr!.set(item: i, value: v) }
        }
        if pending[cmd.key] == nil { order.append(cmd.key) }
        pending[cmd.key] = cmd; pump()
    }
    func pump() {
        guard inFlight == nil, peripheral.state == .connected, let k = order.first, let cmd = pending[k], let ch = chars[cmd.charUUID] else { return }
        order.removeFirst(); pending[k] = nil; inFlight = k
        let d = cmd.encode(); AppLog.write("WRITE \(name) \(d.hex)")
        peripheral.writeValue(d, for: ch, type: .withResponse)
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            for s in p.services ?? [] { AppLog.write("SERVICE \(s.uuid)"); p.discoverCharacteristics(nil, for: s) }
        }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        Task { @MainActor in
            for c in s.characteristics ?? [] {
                AppLog.write("CHAR \(s.uuid)/\(c.uuid) props=\(c.properties.rawValue)")
                if EONGATT2.all.contains(c.uuid.uuidString.uppercased()) {
                    chars[c.uuid.uuidString.uppercased()] = c
                    if c.uuid != CBUUID(string: EONGATT.mixer), c.uuid.uuidString.uppercased() != EONGATT2.locate { p.setNotifyValue(true, for: c); p.readValue(for: c) }
                }
                if c.uuid == CBUUID(string: EONGATT.mixer) {
                    mixerChar = c; p.setNotifyValue(true, for: c); p.readValue(for: c)
                    // Solo pruebas: --test-write "00 00 01 00" --test-restore "00 00 00 00"
                    let a = CommandLine.arguments
                    func hexArg(_ k: String) -> Data? { guard let i = a.firstIndex(of: k), i + 1 < a.count else { return nil }
                        return Data(a[i+1].split(separator: " ").compactMap { UInt8($0, radix: 16) }) }
                    let tcu = a.firstIndex(of: "--test-char").flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
                    var tc = c
                    if let tcu, let found = s.characteristics?.first(where: { $0.uuid.uuidString.uppercased().hasSuffix(tcu.uppercased()) }) { tc = found }
                    if let w = hexArg("--test-write"), let only = a.firstIndex(of: "--connect-name").flatMap({ $0 + 1 < a.count ? a[$0 + 1] : nil }), (p.name ?? "").uppercased().contains(only.uppercased()) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { AppLog.write("TEST-WRITE \(w.hex)"); p.writeValue(w, for: tc, type: .withResponse) }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { p.readValue(for: tc) }
                        if let r = hexArg("--test-restore") {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { AppLog.write("TEST-RESTORE \(r.hex)"); p.writeValue(r, for: tc, type: .withResponse) }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 14) { p.readValue(for: tc) }
                        }
                    }
                    keepAlive?.invalidate()
                    keepAlive = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
                        Task { @MainActor in
                            guard let self, let c = self.mixerChar, self.inFlight == nil, self.peripheral.state == .connected else { return }
                            self.peripheral.readValue(for: c)
                        }
                    }
                } else if c.uuid == CBUUID(string: EONGATT.firmwareRevision) { p.readValue(for: c) }
                else if CommandLine.arguments.contains("--dump"), c.properties.contains(.read) { p.readValue(for: c) }
            }
        }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        let v = c.value; let u = c.uuid
        Task { @MainActor in
            guard let v else { if let error { lastError = error.localizedDescription }; return }
            if u == CBUUID(string: EONGATT.firmwareRevision) { firmware = String(data: v, encoding: .utf8); return }
            if CommandLine.arguments.contains("--dump"), u != CBUUID(string: EONGATT.mixer) { AppLog.write("VALUE \(u) \(v.hex) | \(String(data: v, encoding: .utf8)?.filter { $0.isASCII && !$0.isNewline } ?? "")") }
            let us = u.uuidString.uppercased()
            if us != EONGATT.mixer, EONGATT2.all.contains(us) {
                AppLog.write("NOTIFY \(name) \(us.suffix(12)) \(v.hex)")
                let b = [UInt8](v)
                switch us {
                case EONGATT2.eqTune:
                    if b.count >= 40 { var nb: [EQBand] = []; for i in 0..<8 { nb.append(EQBand(Array(b[i*5..<i*5+5]))) }
                        if let e = editingBand, bands.indices.contains(e), nb.indices.contains(e) { nb[e] = bands[e] }; bands = nb }
                    else if b.count >= 6, bands.indices.contains(Int(b[0])), editingBand != Int(b[0]) { bands[Int(b[0])] = EQBand(Array(b[1..<6])) }
                case EONGATT2.eqStatus: if let x = b.first { eqEnabled = x != 0 }
                case EONGATT2.eqPreset: if let x = b.first { eqPresetIdx = Int(x) }
                case EONGATT2.bass: if let x = b.first { bass = x != 0 }
                case EONGATT2.gain: if b.count >= 2 { for c in 0..<2 where editingGain != c { gains[c] = min(Int(b[c]), 18) } }   // [ganancia C1, ganancia C2]
                case EONGATT2.lock: if let x = b.first { locked = x != 0 }
                case EONGATT2.xlr:
                    if b.count >= 10, var n = XLRState(b) {
                        if let e = editingXLR, let old = xlr { n.set(item: e, value: [old.enabled ? 1 : 0, old.preset, old.hpf / 10, old.lpf / 10, old.level, old.spkDelay, old.outDelay, old.post ? 1 : 0][e]) }
                        xlr = n
                    } else if b.count >= 3, xlr != nil, editingXLR != Int(b[0]) { xlr!.set(item: Int(b[0]), value: Int(b[1]) << 8 | Int(b[2])) }
                default: break
                }
                return
            }
            guard u == CBUUID(string: EONGATT.mixer) else { return }
            AppLog.write("NOTIFY \(name) \(v.hex)")
            var s = state ?? MixerState()
            if s.apply(v) {
                // no pisar lo que el usuario está arrastrando
                if let old = state { for c in editing { s.volume[c] = old.volume[c] } }
                state = s; status = .connected; lastError = nil
            }
        }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        let msg = error?.localizedDescription
        Task { @MainActor in
            inFlight = nil
            if let msg { lastError = "La bocina rechazó el cambio: \(msg)"; AppLog.write("WRITE-ERR \(msg)") }
            pump()
        }
    }
}

struct Found: Identifiable { let id: UUID; let name: String; let peripheral: CBPeripheral }

@MainActor final class Link: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published var speakers: [SpeakerVM] = []      // solo las que el usuario conectó
    @Published var found: [Found] = []             // detectadas, SIN conectar
    @Published var bluetoothState = "Iniciando Bluetooth…"
    @Published var searching = false
    var central: CBCentralManager!
    let defaults = UserDefaults.standard
    var chosen: Set<String> { get { Set(defaults.stringArray(forKey: "chosenIDs") ?? []) } set { defaults.set(Array(newValue), forKey: "chosenIDs") } }
    /// Solo para pruebas: --connect-name EON715
    var argName: String? { let a = CommandLine.arguments; if let i = a.firstIndex(of: "--connect-name"), i + 1 < a.count { return a[i+1].uppercased() }; return nil }

    override init() { super.init(); central = CBCentralManager(delegate: self, queue: .main) }

    func scan() {
        guard central.state == .poweredOn else { return }
        searching = true
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.central.stopScan(); self?.searching = false }
    }
    func connect(_ f: Found) {
        found.removeAll { $0.id == f.id }
        guard !speakers.contains(where: { $0.id == f.id }) else { return }
        chosen.insert(f.id.uuidString)
        let vm = SpeakerVM(peripheral: f.peripheral); vm.central = self; speakers.append(vm)
        AppLog.write("CONNECT \(vm.name)"); central.connect(f.peripheral)
    }
    func disconnect(_ s: SpeakerVM) {
        chosen.remove(s.id.uuidString); s.keepAlive?.invalidate()
        central.cancelPeripheralConnection(s.peripheral); speakers.removeAll { $0.id == s.id }
        AppLog.write("DISCONNECT \(s.name)")
    }
    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        let st = c.state
        Task { @MainActor in
            switch st {
            case .poweredOn: bluetoothState = "Bluetooth activo"; scan()
            case .poweredOff: bluetoothState = "Bluetooth apagado"
            case .unauthorized: bluetoothState = "Sin permiso de Bluetooth: actívalo en Ajustes › Privacidad y seguridad › Bluetooth"
            default: bluetoothState = "Bluetooth no disponible (\(st.rawValue))"
            }
        }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        let name = p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let hasSvc = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.contains(CBUUID(string: EONGATT.service)) ?? false
        guard hasSvc || name.uppercased().contains("EON7") else { return }
        Task { @MainActor in
            guard !speakers.contains(where: { $0.id == p.identifier }), !found.contains(where: { $0.id == p.identifier }) else { return }
            let f = Found(id: p.identifier, name: name.isEmpty ? "JBL EON" : name, peripheral: p)
            AppLog.write("FOUND \(f.name) \(p.identifier)")
            // Solo se conecta sola a una bocina que el usuario eligió antes (o a la indicada por --connect-name)
            if chosen.contains(p.identifier.uuidString) || (argName.map { name.uppercased().contains($0) } ?? false) { connect(f) }
            else { found.append(f) }
        }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        Task { @MainActor in
            speakers.first { $0.id == p.identifier }?.status = .syncing
            p.discoverServices(CommandLine.arguments.contains("--dump") ? nil : [CBUUID(string: EONGATT.service), CBUUID(string: EONGATT.deviceInformation)])
        }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        Task { @MainActor in speakers.first { $0.id == p.identifier }?.lastError = error?.localizedDescription }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        Task { @MainActor in
            // reconecta solo si sigue en la lista de elegidas
            if let s = speakers.first(where: { $0.id == p.identifier }) {
                s.status = .reconnecting; s.keepAlive?.invalidate(); s.mixerChar = nil; s.inFlight = nil
                central.connect(p)
            }
        }
    }
    func rescan() { found.removeAll(); scan() }
}

// MARK: - Temas
struct AppTheme: Identifiable {
    let id: String, name: String, note: String
    let accent: Color, window: Color, panel: Color, stroke: Color
    let scheme: ColorScheme?
    static let all: [AppTheme] = [
        .init(id: "escenario", name: "Escenario", note: "Oscuro con naranja JBL",
              accent: Color(red: 1.0, green: 0.47, blue: 0.08), window: Color(red: 0.07, green: 0.07, blue: 0.08),
              panel: Color(red: 0.13, green: 0.13, blue: 0.15), stroke: Color.white.opacity(0.06), scheme: .dark),
        .init(id: "estudio", name: "Estudio", note: "Grafito con azul hielo",
              accent: Color(red: 0.36, green: 0.68, blue: 1.0), window: Color(red: 0.11, green: 0.12, blue: 0.14),
              panel: Color(red: 0.17, green: 0.18, blue: 0.21), stroke: Color.white.opacity(0.07), scheme: .dark),
        .init(id: "papel", name: "Papel", note: "Claro y cálido con naranja",
              accent: Color(red: 0.93, green: 0.40, blue: 0.05), window: Color(red: 0.95, green: 0.94, blue: 0.92),
              panel: Color.white, stroke: Color.black.opacity(0.07), scheme: .light),
        .init(id: "sistema", name: "Sistema", note: "Sigue el aspecto de macOS",
              accent: Color.accentColor, window: Color(nsColor: .windowBackgroundColor),
              panel: Color(nsColor: .controlBackgroundColor), stroke: Color.primary.opacity(0.08), scheme: nil)
    ]
}
private struct ThemeKey: EnvironmentKey { static let defaultValue = AppTheme.all[0] }
extension EnvironmentValues { var theme: AppTheme { get { self[ThemeKey.self] } set { self[ThemeKey.self] = newValue } } }
struct PanelStyle: ViewModifier {
    @Environment(\.theme) var t
    func body(content: Content) -> some View {
        content.background(RoundedRectangle(cornerRadius: 14).fill(t.panel))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(t.stroke, lineWidth: 1))
    }
}
extension View { func panelStyle() -> some View { modifier(PanelStyle()) } }

// MARK: - UI
struct ChannelRow: View {
    @Environment(\.theme) var t
    @ObservedObject var vm: SpeakerVM; let ch: EONChannel
    var body: some View {
        let idx = vm.state?.volume[ch] ?? 0
        let muted = vm.state?.mute[ch] ?? false
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(ch.label).font(.subheadline.weight(.medium)); Spacer()
                Text(VolumeMap.text(ch, idx)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
            HStack {
                Button { vm.send(.mute(ch, !muted)) } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 22)
                }.buttonStyle(.borderless).foregroundStyle(muted ? Color.secondary : t.accent)
                Slider(value: Binding(get: { Double(idx) }, set: { vm.send(.volume(ch, Int($0.rounded()))) }),
                       in: Double(VolumeMap.range(ch).lowerBound)...Double(VolumeMap.range(ch).upperBound), step: 1) { e in
                    if e { vm.editing.insert(ch) } else { vm.editing.remove(ch) }
                }.opacity(muted ? 0.4 : 1)
            }
        }
    }
}

struct EQSection: View {
    @ObservedObject var vm: SpeakerVM
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ecualizador").font(.headline)
            if vm.bands.isEmpty { Text("Leyendo EQ…").font(.caption).foregroundStyle(.secondary) }
            HStack(alignment: .top, spacing: 6) {
                ForEach(vm.bands.indices, id: \.self) { i in BandRow(vm: vm, i: i) }
            }
        }
        .padding(14).frame(width: 540, alignment: .topLeading)
        .panelStyle()
    }
}

/// Fader vertical propio (el Slider girado no interpreta bien el clic en macOS)
struct VFader: View {
    @Environment(\.theme) var t
    @Binding var value: Double
    let range: ClosedRange<Double>; let step: Double; var onEditing: (Bool) -> Void
    let height: CGFloat = 78
    var body: some View {
        let span = range.upperBound - range.lowerBound
        let frac = CGFloat((value - range.lowerBound) / span)
        let zero = CGFloat((0 - range.lowerBound) / span)
        ZStack(alignment: .top) {
            Capsule().fill(Color.secondary.opacity(0.25)).frame(width: 4, height: height)
            // relleno desde 0 dB hasta el valor
            Capsule().fill(t.accent).frame(width: 4, height: max(2, abs(frac - zero) * height))
                .offset(y: height - max(frac, zero) * height)
            Capsule().fill(Color.secondary.opacity(0.5)).frame(width: 14, height: 1.5).offset(y: height - zero * height)
            RoundedRectangle(cornerRadius: 4).fill(.white).shadow(radius: 1.5)
                .frame(width: 22, height: 12).overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
                .offset(y: height - frac * height - 6)
        }
        .frame(width: 30, height: height + 12).contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                onEditing(true)
                let f = 1 - min(max((g.location.y - 6) / height, 0), 1)
                let v = range.lowerBound + Double(f) * span
                value = min(max((v / step).rounded() * step, range.lowerBound), range.upperBound)
            }
            .onEnded { _ in onEditing(false) })
    }
}

struct BandRow: View {
    @ObservedObject var vm: SpeakerVM; let i: Int
    var body: some View {
        let b = vm.bands[i]
        VStack(spacing: 4) {
            Text(String(format: "%+.1f", b.gain)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            VFader(value: Binding(get: { b.gain }, set: { g in vm.send(.eqBand(i, g, b.freq, b.q)) }),
                   range: EQBand.gainRange, step: 0.1) { vm.editingBand = $0 ? i : nil }
            Button { vm.send(.eqBand(i, 0, b.freq, b.q)) } label: { Text("0").font(.caption2) }
                .buttonStyle(.borderless).help("Ganancia a 0 dB")
            Text("Banda \(i + 1)").font(.caption2.weight(.semibold))
            TextField("Hz", value: Binding(get: { b.freq }, set: { f in vm.send(.eqBand(i, b.gain, max(20, min(20000, f)), b.q)) }), format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.center).frame(width: 54).font(.caption.monospacedDigit()).help("Frecuencia (Hz)")
            TextField("Q", value: Binding(get: { b.q }, set: { q in vm.send(.eqBand(i, b.gain, b.freq, max(0.01, min(16, q)))) }), format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.center).frame(width: 54).font(.caption.monospacedDigit()).help("Q")
        }.frame(width: 58)
    }
}

struct SpeakerCard: View {
    @ObservedObject var vm: SpeakerVM
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(vm.status == .connected ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(vm.title).font(.headline); Spacer()
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            if let f = vm.firmware { Text("Firmware \(f)").font(.caption).foregroundStyle(.secondary) }
            Divider()
            if vm.state != nil {
                ForEach(EONChannel.allCases) { ChannelRow(vm: vm, ch: $0) }
                Divider()
                HStack {
                    Toggle("EQ", isOn: Binding(get: { vm.eqEnabled ?? false }, set: { vm.send(.eqEnable($0)) })).toggleStyle(.switch).controlSize(.small)
                    Spacer()
                    Picker("Preset", selection: Binding(get: { vm.eqPresetIdx ?? 0 }, set: { vm.send(.eqPreset($0)) })) {
                        ForEach(Array(eqPresetNames.enumerated()), id: \.offset) { Text($0.element).tag($0.offset) }
                    }.labelsHidden().frame(width: 110)
                }
                Toggle("Bass boost", isOn: Binding(get: { vm.bass ?? false }, set: { vm.send(.bass($0)) })).toggleStyle(.switch).controlSize(.small)
            }
            else { ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60) }
            if let e = vm.lastError { Text(e).font(.caption).foregroundStyle(.red) }
        }
        .padding(14).frame(width: 300)
        .panelStyle()
        .opacity(vm.status == .connected ? 1 : 0.7)
    }
    var label: String {
        switch vm.status { case .connected: return "Conectada"; case .reconnecting: return "Reconectando…"
        case .syncing: return "Sincronizando…"; case .connecting: return "Conectando…"; default: return "" }
    }
}

struct InputsPanel: View {
    @ObservedObject var vm: SpeakerVM
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Entradas").font(.headline)
            ForEach(0..<2, id: \.self) { c in
                let g = vm.gains[c] ?? 0
                VStack(alignment: .leading, spacing: 2) {
                    HStack { Text("Ganancia Canal \(c + 1)").font(.subheadline.weight(.medium)); Spacer()
                        Text("+\(g * 2) dB").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
                    Slider(value: Binding(get: { Double(g) }, set: { vm.send(.gain(c, Int($0.rounded()))) }), in: 0...18, step: 1) { e in
                        vm.editingGain = e ? c : nil }
                }
            }
            Divider()
            Text("Bocina").font(.headline)
            HStack {
                Button { vm.send(.locate) } label: { Label("Localizar", systemImage: "scope") }
                    .help("Hace parpadear esta bocina")
                Spacer()
            }
            Toggle("Bloquear controles", isOn: Binding(get: { vm.locked ?? false }, set: { vm.send(.lock($0)) }))
                .toggleStyle(.switch).controlSize(.small).help("Bloquea los controles físicos de la bocina")
        }
        .padding(14).frame(width: 240, alignment: .topLeading)
        .panelStyle()
    }
}

struct HzSlider: View {
    let title: String; let hz: Int; let onSet: (Int) -> Void; let onEditing: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title).font(.subheadline.weight(.medium)); Spacer()
                TextField("Hz", value: Binding(get: { hz }, set: { onSet(max(20, min(22000, ($0 / 10) * 10))) }), format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 64).font(.caption.monospacedDigit())
                Text("Hz").font(.caption).foregroundStyle(.secondary) }
            // escala logarítmica 20 Hz – 22 kHz
            Slider(value: Binding(get: { log(Double(max(hz, 20)) / 20) / log(1100) },
                                  set: { onSet(max(20, min(22000, Int((20 * pow(1100, $0) / 10).rounded()) * 10))) }), in: 0...1) { onEditing($0) }
        }
    }
}

struct XLRPanel: View {
    @ObservedObject var vm: SpeakerVM
    var body: some View {
        let x = vm.xlr ?? XLRState()
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Salida XLR").font(.headline); Spacer()
                Toggle("Pass-thru", isOn: Binding(get: { x.enabled }, set: { vm.send(.xlr(0, $0 ? 1 : 0)) })).toggleStyle(.switch).controlSize(.small) }
            VStack(alignment: .leading, spacing: 2) {
                HStack { Text("Nivel de salida").font(.subheadline.weight(.medium)); Spacer()
                    Text(XLRMap.text(x.level)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
                Slider(value: Binding(get: { Double(x.level) }, set: { vm.send(.xlr(4, Int($0.rounded()))) }), in: 0...87, step: 1) { vm.editingXLR = $0 ? 4 : nil }
            }
            HzSlider(title: "Pasa-bajos de salida (LPF)", hz: x.lpf, onSet: { vm.send(.xlr(3, $0 / 10)) }, onEditing: { vm.editingXLR = $0 ? 3 : nil })
            HzSlider(title: "Pasa-altos de la bocina (HPF)", hz: x.hpf, onSet: { vm.send(.xlr(2, $0 / 10)) }, onEditing: { vm.editingXLR = $0 ? 2 : nil })
            VStack(alignment: .leading, spacing: 2) {
                HStack { Text("Retardo bocina").font(.subheadline.weight(.medium)); Spacer(); Text("\(x.spkDelay)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
                Slider(value: Binding(get: { Double(x.spkDelay) }, set: { vm.send(.xlr(5, Int($0.rounded()))) }), in: 0...100, step: 1) { vm.editingXLR = $0 ? 5 : nil }
                HStack { Text("Retardo salida").font(.subheadline.weight(.medium)); Spacer(); Text("\(x.outDelay)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
                Slider(value: Binding(get: { Double(x.outDelay) }, set: { vm.send(.xlr(6, Int($0.rounded()))) }), in: 0...100, step: 1) { vm.editingXLR = $0 ? 6 : nil }
            }
            Picker("", selection: Binding(get: { x.post ? 1 : 0 }, set: { vm.send(.xlr(7, $0)) })) { Text("Pre").tag(0); Text("Post").tag(1) }
                .pickerStyle(.segmented).labelsHidden()
        }
        .padding(14).frame(width: 270, alignment: .topLeading)
        .panelStyle()
    }
}

struct SpeakerRow: View {
    @ObservedObject var vm: SpeakerVM; var onClose: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SpeakerCard(vm: vm).overlay(alignment: .topTrailing) {
                Button(action: onClose) { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).help("Desconectar").padding(6) }
            if vm.state != nil {
                EQSection(vm: vm)
                InputsPanel(vm: vm)
                if vm.xlr != nil { XLRPanel(vm: vm) }
                // Las nuevas funciones se añaden aquí, a la derecha
            }
        }
    }
}

struct ContentView: View {
    @StateObject var link = Link()
    @AppStorage("theme") var themeID = "escenario"
    var theme: AppTheme { AppTheme.all.first { $0.id == themeID } ?? AppTheme.all[0] }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("JBL EON Control").font(.title2.bold()); Spacer()
                Menu {
                    ForEach(AppTheme.all) { th in
                        Button { themeID = th.id } label: { Label("\(th.name) — \(th.note)", systemImage: th.id == themeID ? "checkmark" : "paintpalette") }
                    }
                } label: { Label("Tema", systemImage: "paintpalette") }.fixedSize()
                Button { link.rescan() } label: { Label("Buscar", systemImage: "arrow.clockwise") } }
            if !link.speakers.isEmpty {
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(link.speakers) { sp in SpeakerRow(vm: sp) { link.disconnect(sp) } }
                    }.padding(.bottom, 8)
                }
            }
            if !link.found.isEmpty {
                Text("Bocinas detectadas").font(.subheadline).foregroundStyle(.secondary)
                ForEach(link.found) { f in
                    HStack { Image(systemName: "hifispeaker"); Text(f.name); Spacer(); Button("Conectar") { link.connect(f) } }
                        .padding(10).panelStyle()
                }
            }
            if link.speakers.isEmpty && link.found.isEmpty {
                VStack(spacing: 8) {
                    if link.searching { ProgressView().controlSize(.small) }
                    Text(link.searching ? "Buscando bocinas JBL EON700…" : link.bluetoothState).foregroundStyle(.secondary)
                    if !link.searching { Button("Volver a buscar bocinas") { link.scan() } }
                }.frame(maxWidth: .infinity, minHeight: 160)
            }
            Spacer(minLength: 0)
        }.padding(20).frame(minWidth: 460, minHeight: 360)
        .background(theme.window).environment(\.theme, theme).tint(theme.accent).preferredColorScheme(theme.scheme)
    }
}

@main struct EONControlApp: App {
    var body: some Scene { WindowGroup("JBL EON Control") { ContentView() }.windowResizability(.contentMinSize).defaultSize(width: 1560, height: 640) }
}
