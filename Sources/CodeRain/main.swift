import SwiftUI
import AppKit
import CoreText
import Carbon.HIToolbox
import Darwin

// MARK: - CPU Sampler (external = total - self)

final class CPUSampler: ObservableObject {
    @Published var externalLoad: Double = 0
    @Published var totalLoad: Double = 0
    @Published var selfLoad: Double = 0

    private var prevTicks: (UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0)
    private var prevSelfCPU: Double = 0
    private var prevWall: Double = 0
    private let ncpu: Double = Double(ProcessInfo.processInfo.activeProcessorCount)
    private var timer: Timer?

    func start() {
        prevWall = CACurrentMediaTime()
        _ = sampleHostTicks()
        prevSelfCPU = sampleSelfCPU()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func sampleHostTicks() -> (UInt32, UInt32, UInt32, UInt32)? {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info()
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return (UInt32(info.cpu_ticks.0), UInt32(info.cpu_ticks.1),
                UInt32(info.cpu_ticks.2), UInt32(info.cpu_ticks.3))
    }

    private func sampleSelfCPU() -> Double {
        var r = rusage()
        getrusage(RUSAGE_SELF, &r)
        let u = Double(r.ru_utime.tv_sec) + Double(r.ru_utime.tv_usec) / 1_000_000
        let s = Double(r.ru_stime.tv_sec) + Double(r.ru_stime.tv_usec) / 1_000_000
        return u + s
    }

    private func tick() {
        guard let cur = sampleHostTicks() else { return }
        let uD = cur.0 &- prevTicks.0
        let sD = cur.1 &- prevTicks.1
        let iD = cur.2 &- prevTicks.2
        let nD = cur.3 &- prevTicks.3
        prevTicks = cur
        let total = Double(uD) + Double(sD) + Double(iD) + Double(nD)
        guard total > 0 else { return }
        let totalLoad = 1.0 - Double(iD) / total

        let curSelf = sampleSelfCPU()
        let now = CACurrentMediaTime()
        let wallDiff = now - prevWall
        let selfDiff = curSelf - prevSelfCPU
        prevSelfCPU = curSelf
        prevWall = now
        let selfFrac = wallDiff > 0 ? (selfDiff / wallDiff) / ncpu : 0
        let external = max(0, totalLoad - selfFrac)

        DispatchQueue.main.async {
            self.totalLoad = self.totalLoad * 0.4 + totalLoad * 0.6
            self.selfLoad = self.selfLoad * 0.4 + selfFrac * 0.6
            self.externalLoad = self.externalLoad * 0.4 + external * 0.6
        }
    }
}

// MARK: - Glitch Engine (digital corruption vocabulary: frozen threads + bit rot)

final class GlitchEngine {
    /// col index → frames remaining frozen
    var frozen: [Int: Int] = [:]
    /// per-draw char corruption probability
    var corruptionRate: Double = 0

    /// Glyphs that read as "壞掉的字元"（方塊、區塊、unknown glyph 感）
    static let glitchGlyphs: [Character] = Array("█▓▒░▀▄▌▐■□◈◆◇◊⬛⬜�")

    /// Visually-weighted load — pushes mid-range CPU to more impact
    static func visualLoad(_ raw: Double) -> Double {
        pow(max(0, min(1, raw)), 0.6)
    }

    func tick(cpuLoad: Double, columnCount: Int) {
        let v = Self.visualLoad(cpuLoad)
        corruptionRate = v * 0.18   // 0% → 18% chars glitch at full load

        // Spawn frozen columns: rate ∝ load × column count
        let expected = v * Double(columnCount) * 0.008
        var spawns = Int(expected)
        if Double.random(in: 0...1) < (expected - Double(spawns)) { spawns += 1 }
        for _ in 0..<spawns {
            let idx = Int.random(in: 0..<columnCount)
            if frozen[idx] == nil {
                frozen[idx] = Int.random(in: 20 ... 90) // ~0.3–1.5s at 60fps
            }
        }
        // Age out
        for (k, v) in frozen {
            let nv = v - 1
            if nv <= 0 { frozen.removeValue(forKey: k) } else { frozen[k] = nv }
        }
    }

    func isFrozen(_ col: Int) -> Bool { frozen[col] != nil }

    func maybeCorruptChar(_ normal: Character) -> Character {
        if Double.random(in: 0...1) < corruptionRate {
            return Self.glitchGlyphs.randomElement() ?? normal
        }
        return normal
    }
}

// MARK: - Matrix Rain NSView (bitmap persistence → canonical Matrix feel)

final class MatrixRainNSView: NSView {
    var sampler: CPUSampler?
    let glitch = GlitchEngine()

    private let sz: CGFloat = 20
    private let charPool: [Character] = Array(
        "アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲン0123456789"
    )
    private var backBuffer: CGContext?
    private var bufferPixelSize: CGSize = .zero
    private var drops: [CGFloat] = []        // position in "chars"
    private var dropSpeeds: [CGFloat] = []   // chars per frame @ 60fps
    private var lastDrawn: [Int] = []        // last integer row index drawn per column
    private var lineCache: [Character: CTLine] = [:]
    private var headCache: [Character: CTLine] = [:]
    private var timer: Timer?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .nearest   // 方塊像素放大，不要雙線性模糊
        layer?.minificationFilter = .nearest
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setupBuffer()
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.step()
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    override func layout() {
        super.layout()
        setupBuffer()
    }

    private func setupBuffer() {
        // Render at 1x (logical pixels). Layer upscales with nearest filter →
        // 1/4 the bitmap workload on retina, crunchier 8-bit look.
        let pw = bounds.width
        let ph = bounds.height
        let newSize = CGSize(width: pw, height: ph)
        guard pw > 0, ph > 0, newSize != bufferPixelSize else { return }
        bufferPixelSize = newSize

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: Int(pw), height: Int(ph),
            bitsPerComponent: 8, bytesPerRow: Int(pw) * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: bounds.size))
        backBuffer = ctx

        let cols = max(1, Int(bounds.width / sz))
        drops = (0..<cols).map { _ in CGFloat.random(in: 0 ... bounds.height / sz) }
        // Per-column speed, biased toward slow with occasional fast lanes.
        // At 60fps, 0.33 chars/frame ≈ 400 px/s (matches reference 20fps×1char).
        dropSpeeds = (0..<cols).map { _ in
            CGFloat(0.15 + pow(Double.random(in: 0...1), 1.7) * 0.6) // 0.15 – 0.75
        }
        lastDrawn = Array(repeating: -1, count: cols)

        buildCTLineCache()
    }

    /// Build a single CTLine on demand (for glitch glyphs outside the pool)
    fileprivate static func buildLine(char: Character, white: Bool) -> CTLine {
        let font = NSFont.monospacedSystemFont(ofSize: 20, weight: .bold)
        let color: CGColor = white
            ? CGColor(red: 0.85, green: 1, blue: 0.92, alpha: 1)
            : CGColor(red: 0, green: 1, blue: 0.25, alpha: 1)
        let s = NSAttributedString(string: String(char), attributes: [
            .font: font, .foregroundColor: color
        ])
        return CTLineCreateWithAttributedString(s)
    }

    private func buildCTLineCache() {
        lineCache.removeAll()
        headCache.removeAll()
        let font = CTFontCreateWithName("JetBrainsMono-Bold" as CFString, sz, nil)
        // Fallback if JetBrains Mono not installed:
        let actualFont: CTFont = {
            let name = CTFontCopyPostScriptName(font) as String
            if name.lowercased().contains("jetbrains") { return font }
            let fallback = NSFont.monospacedSystemFont(ofSize: sz, weight: .bold)
            return fallback as CTFont
        }()
        let greenColor = CGColor(red: 0, green: 1, blue: 0.25, alpha: 1)
        let whiteColor = CGColor(red: 0.85, green: 1, blue: 0.92, alpha: 1)
        for ch in charPool {
            let body = NSAttributedString(string: String(ch), attributes: [
                .font: actualFont,
                .foregroundColor: greenColor
            ])
            lineCache[ch] = CTLineCreateWithAttributedString(body)
            let head = NSAttributedString(string: String(ch), attributes: [
                .font: actualFont,
                .foregroundColor: whiteColor
            ])
            headCache[ch] = CTLineCreateWithAttributedString(head)
        }
    }

    private func step() {
        guard let ctx = backBuffer, bounds.width > 0 else { return }
        let load = sampler?.externalLoad ?? 0

        // 1) Fade previous frame. Alpha pushed to 0.06 so AA residue drops below
        //    8-bit rounding floor — avoids the ghost grid of lingering value-1 pixels.
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.025))
        ctx.fill(CGRect(origin: .zero, size: bounds.size))

        // No antialiasing on chars → sharp pixel edges, zero gray residue.
        // Bonus: "8-bit pixel" feel matches the digital-glitch vocabulary.
        ctx.setShouldAntialias(false)
        ctx.setShouldSmoothFonts(false)

        // Movie-accurate: glyphs are horizontally mirrored (drawn right-to-left
        // from textPosition, so x must be offset by the glyph width below).
        ctx.textMatrix = CGAffineTransform(scaleX: -1, y: 1)

        // 2) Pure Matrix rain — no CPU-driven interference (it got dirty over time)
        _ = load // kept alive for future use (HUD / optional subtle effects)
        for i in drops.indices {
            drops[i] += dropSpeeds[i]
            let idx = Int(drops[i])
            if idx != lastDrawn[i] {
                lastDrawn[i] = idx
                let ch = charPool.randomElement()!
                let line: CTLine = (Int.random(in: 0..<12) == 0 ? headCache[ch] : lineCache[ch]) ?? lineCache[ch]!
                let yScreen = CGFloat(idx) * sz
                let xScreen = CGFloat(i) * sz
                let yCG = bounds.height - yScreen - sz * 0.25
                let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                ctx.textPosition = CGPoint(x: xScreen + w, y: yCG)
                CTLineDraw(line, ctx)
            }
            if drops[i] * sz > bounds.height && CGFloat.random(in: 0...1) > 0.975 {
                drops[i] = 0
                lastDrawn[i] = -1
            }
        }

        // 4) Present
        if let img = ctx.makeImage() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contents = img
            CATransaction.commit()
        }
    }
}

// MARK: - SwiftUI wrapper + HUD

struct MatrixRainRepresentable: NSViewRepresentable {
    let sampler: CPUSampler
    func makeNSView(context: Context) -> MatrixRainNSView {
        let v = MatrixRainNSView()
        v.sampler = sampler
        return v
    }
    func updateNSView(_ v: MatrixRainNSView, context: Context) {}
}

struct CodeRainView: View {
    @ObservedObject var sampler: CPUSampler
    var body: some View {
        ZStack(alignment: .topLeading) {
            MatrixRainRepresentable(sampler: sampler)
            Text("""
            EXT CPU: \(Int(sampler.externalLoad * 100))%
            TOTAL:   \(Int(sampler.totalLoad * 100))%
            SELF:    \(Int(sampler.selfLoad * 100))%
            """)
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(.green.opacity(0.85))
            .padding(20)
        }
        .background(Color.black)
        .ignoresSafeArea()
    }
}

// MARK: - Idle Monitor

/// Idle threshold in seconds. Change to 30 for quick testing.
let idleThresholdSeconds: TimeInterval = 180

final class IdleMonitor {
    var onIdle: (() -> Void)?
    var onWake: (() -> Void)?
    private var timer: Timer?
    private var triggered = false

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    private func check() {
        let idle = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: CGEventType(rawValue: ~0)!
        )
        if !triggered, idle >= idleThresholdSeconds {
            triggered = true
            onIdle?()
        } else if triggered, idle < 2 {
            triggered = false
            onWake?()
        }
    }

    func forceTrigger() {
        guard !triggered else { return }
        triggered = true
        onIdle?()
    }
}

// MARK: - Screensaver Controller (one window per screen)

final class ScreensaverController {
    let sampler = CPUSampler()
    private var windows: [NSWindow] = []
    private var eventMonitor: Any?
    private var dismissEnabledAt: Date = .distantPast

    init() { sampler.start() }

    var isShowing: Bool { !windows.isEmpty }

    func show() {
        guard windows.isEmpty else { return }
        for screen in NSScreen.screens {
            let w = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            w.isOpaque = true
            w.backgroundColor = .black
            w.hasShadow = false
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            let host = NSHostingView(rootView: CodeRainView(sampler: sampler))
            host.frame = NSRect(origin: .zero, size: screen.frame.size)
            w.contentView = host
            w.setFrame(screen.frame, display: true)
            w.makeKeyAndOrderFront(nil)
            windows.append(w)
        }
        // Grace period so releasing the hotkey modifiers / hand-jitter
        // right after triggering doesn't dismiss immediately.
        dismissEnabledAt = Date().addingTimeInterval(0.6)
        // No .flagsChanged — otherwise every Ctrl/Cmd release would dismiss.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown,
            .otherMouseDown, .scrollWheel
        ]) { [weak self] _ in
            guard let self = self else { return nil }
            if Date() >= self.dismissEnabledAt { self.hide() }
            return nil
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        if let m = eventMonitor {
            NSEvent.removeMonitor(m)
            eventMonitor = nil
        }
    }
}

// MARK: - Global hotkey (Carbon — no Accessibility prompt)

final class GlobalHotKey {
    static let shared = GlobalHotKey()
    var onPress: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Register Ctrl+Opt+Cmd+M (keyCode kVK_ANSI_M = 46)
    func register(keyCode: UInt32 = UInt32(kVK_ANSI_M),
                  modifiers: UInt32 = UInt32(cmdKey | controlKey | optionKey)) {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                GlobalHotKey.shared.onPress?()
                return noErr
            },
            1, &spec, nil, &handlerRef
        )
        let hkID = EventHotKeyID(signature: 0x434F4452 /* 'CODR' */, id: 1)
        RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

// MARK: - App delegate + status-bar menu

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = ScreensaverController()
    let idleMonitor = IdleMonitor()
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        idleMonitor.onIdle = { [weak self] in self?.controller.show() }
        idleMonitor.onWake = { [weak self] in self?.controller.hide() }
        idleMonitor.start()

        // ⌃⌘M — toggle show/hide
        GlobalHotKey.shared.onPress = { [weak self] in
            guard let self = self else { return }
            if self.controller.isShowing { self.controller.hide() }
            else { self.controller.show() }
        }
        GlobalHotKey.shared.register()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⣿"
        let menu = NSMenu()
        menu.addItem(menuItem(title: "Test Now  (⌃⌥⌘M)", action: #selector(testNow(_:)), key: ""))
        menu.addItem(menuItem(title: "Dismiss", action: #selector(dismiss(_:)), key: ""))
        menu.addItem(.separator())
        let info = NSMenuItem(title: "Idle threshold: \(Int(idleThresholdSeconds))s",
                              action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Quit", action: #selector(quit(_:)), key: "q"))
        statusItem.menu = menu
    }

    private func menuItem(title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc func testNow(_ sender: Any?) { controller.show() }
    @objc func dismiss(_ sender: Any?) { controller.hide() }
    @objc func quit(_ sender: Any?) { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
