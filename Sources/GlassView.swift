import Cocoa
import ScreenCaptureKit
import CoreMedia
import ApplicationServices

// Draws a click-through "glass" copy of another app's window on top of it.
// The real window keeps receiving all clicks/keys (no input lag). The copy blends the
// window's pixels with whatever is behind it, so the opacity slider works.

final class FrameSink: NSObject, SCStreamOutput {
    let handler: @Sendable (CVPixelBuffer) -> Void
    init(_ h: @escaping @Sendable (CVPixelBuffer) -> Void) { handler = h }
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = arr.first?[.status] as? Int, raw == SCFrameStatus.complete.rawValue,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        handler(pb)
    }
}

func present(_ pb: CVPixelBuffer, on layer: CALayer) {
    guard let surf = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() else { return }
    DispatchQueue.main.async {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = surf
        CATransaction.commit()
    }
}

final class GlassFX: @unchecked Sendable {
    static let shared = GlassFX()
    private let lock = NSLock()
    private var _c = 1.0
    private var _s = 1.0
    var contrast: Double {
        get { lock.lock(); defer { lock.unlock() }; return _c }
        set { lock.lock(); _c = newValue; lock.unlock() }
    }
    var saturation: Double {
        get { lock.lock(); defer { lock.unlock() }; return _s }
        set { lock.lock(); _s = newValue; lock.unlock() }
    }
    private var _bg: CVPixelBuffer?
    private var _frac = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var _avg = false
    var useAverage: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _avg }
        set { lock.lock(); _avg = newValue; lock.unlock() }
    }
    func setBackdrop(_ pb: CVPixelBuffer) { lock.lock(); _bg = pb; lock.unlock() }
    func setRegion(_ r: CGRect) { lock.lock(); _frac = r; lock.unlock() }
    let ctx = CIContext()
    var pool: CVPixelBufferPool?
    var poolW = 0
    var poolH = 0

    func makeBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer? {
        if pool == nil || poolW != w || poolH != h {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
            var np: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary, attrs as CFDictionary, &np)
            pool = np
            poolW = w
            poolH = h
        }
        guard let pl = pool else { return nil }
        var b: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pl, &b)
        return b
    }

    func process(_ pb: CVPixelBuffer) -> CVPixelBuffer {
        let c = contrast
        let sat = saturation
        if c >= 0.999 && sat >= 0.999 { return pb }
        var img = CIImage(cvPixelBuffer: pb)
        let ext = img.extent
        if sat < 0.999, let f = CIFilter(name: "CIColorControls") {
            f.setValue(img, forKey: kCIInputImageKey)
            f.setValue(sat, forKey: kCIInputSaturationKey)
            if let o = f.outputImage { img = o }
        }
        if c < 0.999 {
            lock.lock()
            let bg = _bg
            let fr = _frac
            let avgMode = _avg
            lock.unlock()
            var target: CIImage?
            if let bg = bg {
                let bi = CIImage(cvPixelBuffer: bg)
                let be = bi.extent
                let r = CGRect(x: fr.minX * be.width, y: fr.minY * be.height, width: fr.width * be.width, height: fr.height * be.height)
                if r.width > 1 && r.height > 1 {
                    var t = bi.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
                    if avgMode,
                       let a = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: t, kCIInputExtentKey: CIVector(cgRect: t.extent)])?.outputImage {
                        t = a.clampedToExtent()
                    } else {
                        t = t.transformed(by: CGAffineTransform(scaleX: ext.width / r.width, y: ext.height / r.height))
                    }
                    target = t.cropped(to: ext)
                }
            }
            if target == nil,
               let a = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: img, kCIInputExtentKey: CIVector(cgRect: ext)])?.outputImage {
                target = a.clampedToExtent().cropped(to: ext)
            }
            if let tg = target, let d = CIFilter(name: "CIDissolveTransition") {
                d.setValue(img, forKey: kCIInputImageKey)
                d.setValue(tg, forKey: kCIInputTargetImageKey)
                d.setValue(1.0 - c, forKey: kCIInputTimeKey)
                if let o = d.outputImage { img = o }
            }
        }
        guard let out = makeBuffer(CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb)) else { return pb }
        ctx.render(img, to: out)
        return out
    }
}

final class OverlayWindow: NSWindow { override func constrainFrameRect(_ f: NSRect, to s: NSScreen?) -> NSRect { return f } }

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, SCStreamDelegate {
    var statusItem: NSStatusItem!
    var statusLine: NSMenuItem!
    var overlay: NSWindow?
    var topLayer = CALayer()      // the target window, drawn at the chosen opacity
    var bottomLayer = CALayer()   // what is behind the target window
    var winStream: SCStream?
    var bgStream: SCStream?
    var sinkA: FrameSink?
    var sinkB: FrameSink?
    var target: SCWindow?
    var overlaySC: SCWindow?
    var displays: [SCDisplay] = []
    var targetPID: pid_t = 0
    var lastBounds = CGRect.zero
    var lastSizeApplied = CGSize.zero
    var attaching = false
    var reconfiguring = false
    var pending = false
    var askedPerm = false
    var panelShown = false
    var placing = false
    var keepOpen = false
    var askedAX = false
    var shownAt = Date.distantPast
    var menu = NSMenu()
    var lastSearch = Date.distantPast
    var lastChange = Date.distantPast
    var needsSettle = false
    let qA = DispatchQueue(label: "glass.a")
    let qB = DispatchQueue(label: "glass.b")
    var targetName = UserDefaults.standard.string(forKey: "tname") ?? "Roblox"
    var targetBundle = UserDefaults.standard.string(forKey: "tbid") ?? "com.roblox.RobloxPlayer"
    var targetItem = NSMenuItem()

    func posKey(_ k: String) -> String { k + "." + targetBundle }

    func isTarget(bid: String, name: String) -> Bool {
        if targetBundle == "com.roblox.RobloxPlayer" {
            let b = bid.lowercased()
            let n = name.lowercased()
            return (b.contains("roblox") || n.contains("roblox")) && !b.contains("studio") && !n.contains("studio")
        }
        return bid == targetBundle
    }

    var opacity: Double {
        get { let o = UserDefaults.standard.double(forKey: "opacity"); return o == 0 ? 0.5 : o }
        set { UserDefaults.standard.set(newValue, forKey: "opacity") }
    }

    // MARK: Setup

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let img = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "Glass")
        img?.isTemplate = true
        statusItem.button?.image = img

        menu = NSMenu()
        statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        let opItem = NSMenuItem()
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 210, height: 30))
        let label = NSTextField(labelWithString: "Opacity")
        label.font = .systemFont(ofSize: 13)
        label.frame = NSRect(x: 14, y: 6, width: 56, height: 18)
        let slider = NSSlider(value: opacity, minValue: 0.01, maxValue: 1.0, target: self, action: #selector(opacitySlid(_:)))
        slider.isContinuous = true
        slider.frame = NSRect(x: 74, y: 5, width: 122, height: 20)
        box.addSubview(label)
        box.addSubview(slider)
        opItem.view = box
        menu.addItem(opItem)
        menu.addItem(.separator())

        let sFull = NSMenuItem(title: "Window size: Fullscreen", action: #selector(sizeFull), keyEquivalent: "")
        sFull.target = self
        menu.addItem(sFull)
        let sMini = NSMenuItem(title: "Window size: Mini", action: #selector(sizeMini), keyEquivalent: "")
        sMini.target = self
        menu.addItem(sMini)
        let sTiny = NSMenuItem(title: "Window size: Tiny", action: #selector(sizeTiny), keyEquivalent: "")
        sTiny.target = self
        menu.addItem(sTiny)
        let sSmall = NSMenuItem(title: "Window size: Small", action: #selector(sizeSmall), keyEquivalent: "")
        sSmall.target = self
        menu.addItem(sSmall)
        let sMed = NSMenuItem(title: "Window size: Medium", action: #selector(sizeMedium), keyEquivalent: "")
        sMed.target = self
        menu.addItem(sMed)
        targetItem = NSMenuItem(title: "Target: \(targetName)", action: nil, keyEquivalent: "")
        targetItem.submenu = NSMenu()
        menu.addItem(targetItem)
        let keepItem = NSMenuItem(title: "Keep open", action: #selector(toggleKeepOpen(_:)), keyEquivalent: "")
        keepItem.target = self
        menu.addItem(keepItem)
        let openItem = NSMenuItem(title: "Open \(targetName)", action: #selector(openRoblox), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        if let b = statusItem.button {
            b.target = self
            b.action = #selector(statusClicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier ?? 0
            Task { @MainActor in self?.appActivated(pid) }
        }

        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            let loc = NSEvent.mouseLocation
            Task { @MainActor in self?.clickedAt(loc) }
        }
        setStatus("Click the icon to open \(targetName)")
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func setStatus(_ s: String) {
        statusLine?.title = s
        statusItem?.button?.toolTip = s
    }

    // MARK: Window geometry

    func cgInfo(_ id: CGWindowID) -> (CGRect, Bool)? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let d = list.first(where: { ($0[kCGWindowNumber as String] as? CGWindowID) == id }),
              let bd = d[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: bd as CFDictionary) else { return nil }
        return (r, (d[kCGWindowIsOnscreen as String] as? Bool) ?? false)
    }

    func nsFrame(_ b: CGRect) -> NSRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: b.minX, y: h - b.maxY, width: b.width, height: b.height)
    }

    func scale(for d: SCDisplay) -> CGFloat {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == d.displayID
        }?.backingScaleFactor ?? 2
    }

    // MARK: Per-frame loop

    func tick() {
        if let t = target {
            guard let info = cgInfo(t.windowID) else { detach("\(targetName) window closed. Waiting…"); return }
            let want = panelShown && info.1
            if overlay?.isVisible == true && !want { overlay?.orderOut(nil) }
            if overlay?.isVisible == false && want { overlay?.orderFrontRegardless() }
            if !info.1 { return }
            if info.0 != lastBounds {
                lastBounds = info.0
                if panelShown, !placing, !fullMode {
                    UserDefaults.standard.set(Double(info.0.minX), forKey: posKey("wx"))
                    UserDefaults.standard.set(Double(info.0.minY), forKey: posKey("wy"))
                }
                overlay?.setFrame(nsFrame(outer(info.0)), display: true)
                layoutLayers(info.0)
                scheduleReconfigure()
                lastChange = Date()
                needsSettle = true
            }
            if needsSettle, !placing, Date().timeIntervalSince(lastChange) > 0.4 {
                needsSettle = false
                lastSizeApplied = .zero
                scheduleReconfigure()
            }
        } else if panelShown, !attaching, Date().timeIntervalSince(lastSearch) > 1 {
            Task { @MainActor in await self.attach() }
        }
    }

    // MARK: Attach / detach

    func pickTarget(_ c: SCShareableContent) -> SCWindow? {
        let cands = c.windows.filter { w in
            guard let app = w.owningApplication, app.processID != getpid(), w.isOnScreen, w.windowLayer == 0,
                  w.frame.width > 150, w.frame.height > 100 else { return false }
            return isTarget(bid: app.bundleIdentifier, name: app.applicationName)
        }
        if let f = axWindowFrame() {
            func dist(_ a: CGRect) -> CGFloat { abs(a.minX - f.minX) + abs(a.minY - f.minY) + abs(a.width - f.width) + abs(a.height - f.height) }
            if let m = cands.min(by: { dist($0.frame) < dist($1.frame) }), dist(m.frame) < 8 { return m }
        }
        return cands.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    func attach() async {
        attaching = true
        defer { attaching = false }
        lastSearch = Date()
        if !CGPreflightScreenCaptureAccess() {
            if !askedPerm { askedPerm = true; _ = CGRequestScreenCaptureAccess() }
            setStatus("Needs Screen Recording permission (then relaunch)")
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let win = pickTarget(content) else { setStatus("Waiting for \(targetName)…"); return }
            try await start(win, content)
            if panelShown { placeUnderIcon() }
        } catch {
            detach("Error: \(error.localizedDescription)")
        }
    }

    func buildOverlay(_ frame: NSRect) {
        let w = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.isOpaque = true
        w.backgroundColor = .black
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let v = NSView(frame: NSRect(origin: .zero, size: frame.size))
        v.wantsLayer = true
        v.autoresizingMask = [.width, .height]
        bottomLayer = CALayer()
        topLayer = CALayer()
        for l in [bottomLayer, topLayer] {
            l.frame = v.bounds
            l.contentsGravity = .resize
            l.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            v.layer?.addSublayer(l)
        }
        topLayer.opacity = Float(opacity)
        w.contentView = v
        topLayer.autoresizingMask = []
        applyFilters()
        overlay = w
    }

    let margin: CGFloat = 60
    func outer(_ b: CGRect) -> CGRect {
        let o = b.insetBy(dx: -margin, dy: -margin)
        if let d = displays.first(where: { $0.frame.contains(CGPoint(x: b.midX, y: b.midY)) }) ?? displays.first {
            let r = o.intersection(d.frame)
            if !r.isNull { return r }
        }
        return o
    }
    func layoutLayers(_ b: CGRect) {
        let o = outer(b)
        GlassFX.shared.setRegion(CGRect(x: (b.minX - o.minX) / o.width, y: (o.maxY - b.maxY) / o.height, width: b.width / o.width, height: b.height / o.height))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        topLayer.frame = CGRect(x: b.minX - o.minX, y: o.maxY - b.maxY, width: b.width, height: b.height)
        CATransaction.commit()
    }

    func baseConfig(_ w: CGFloat, _ h: CGFloat, _ s: CGFloat) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = max(2, Int(w * s))
        c.height = max(2, Int(h * s))
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.showsCursor = false
        c.queueDepth = 3
        c.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        return c
    }

    func parts(_ b: CGRect) -> (SCContentFilter, SCStreamConfiguration, SCContentFilter, SCStreamConfiguration)? {
        guard let t = target,
              let d = displays.first(where: { $0.frame.contains(CGPoint(x: b.midX, y: b.midY)) }) ?? displays.first else { return nil }
        let s = scale(for: d)
        let ca = baseConfig(b.width, b.height, s)
        if #available(macOS 14.0, *) { ca.ignoreShadowsSingleWindow = true }
        let fa = SCContentFilter(desktopIndependentWindow: t)
        let ob = outer(b)
        let rel = CGRect(x: ob.minX - d.frame.minX, y: ob.minY - d.frame.minY, width: ob.width, height: ob.height)
            .intersection(CGRect(origin: .zero, size: d.frame.size))
        guard !rel.isNull, rel.width > 1, rel.height > 1 else { return nil }
        let cb = baseConfig(rel.width, rel.height, s)
        cb.sourceRect = rel
        if #available(macOS 14.0, *) { cb.ignoreShadowsDisplay = true }
        cb.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        var excluded: [SCWindow] = [t]
        if let o = overlaySC { excluded.append(o) }
        let fb = SCContentFilter(display: d, excludingWindows: excluded)
        return (fa, ca, fb, cb)
    }

    func start(_ win: SCWindow, _ content: SCShareableContent) async throws {
        target = win
        targetPID = win.owningApplication?.processID ?? 0
        displays = content.displays
        guard let info = cgInfo(win.windowID) else {
            throw NSError(domain: "glass", code: 1, userInfo: [NSLocalizedDescriptionKey: "window vanished"])
        }
        let b = info.0
        lastBounds = b
        lastSizeApplied = b.size
        buildOverlay(nsFrame(outer(b)))
        layoutLayers(b)
        overlay?.orderFrontRegardless()

        overlaySC = nil
        for _ in 0..<15 {
            let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let ov = overlay, let w = c.windows.first(where: { $0.windowID == CGWindowID(ov.windowNumber) }) {
                overlaySC = w
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let p = parts(b) else {
            throw NSError(domain: "glass", code: 2, userInfo: [NSLocalizedDescriptionKey: "no display for window"])
        }
        let layerA = topLayer
        let layerB = bottomLayer
        let a = SCStream(filter: p.0, configuration: p.1, delegate: self)
        let sa = FrameSink { pb in present(GlassFX.shared.process(pb), on: layerA) }
        try a.addStreamOutput(sa, type: .screen, sampleHandlerQueue: qA)
        let bs = SCStream(filter: p.2, configuration: p.3, delegate: self)
        let sb = FrameSink { pb in GlassFX.shared.setBackdrop(pb); present(pb, on: layerB) }
        try bs.addStreamOutput(sb, type: .screen, sampleHandlerQueue: qB)
        sinkA = sa
        sinkB = sb
        winStream = a
        bgStream = bs
        try await a.startCapture()
        try await bs.startCapture()
        setStatus("Glass on: \(win.owningApplication?.applicationName ?? targetName)")
    }

    func scheduleReconfigure() {
        if reconfiguring { pending = true; return }
        reconfiguring = true
        Task { @MainActor in
            repeat {
                pending = false
                let b = lastBounds
                if let p = parts(b) {
                    if b.size != lastSizeApplied {
                        try? await winStream?.updateConfiguration(p.1)
                        lastSizeApplied = b.size
                    }
                    try? await bgStream?.updateContentFilter(p.2)
                    try? await bgStream?.updateConfiguration(p.3)
                }
            } while pending
            reconfiguring = false
        }
    }

    func detach(_ msg: String) {
        let a = winStream
        let b = bgStream
        winStream = nil
        bgStream = nil
        sinkA = nil
        sinkB = nil
        target = nil
        overlaySC = nil
        overlay?.orderOut(nil)
        overlay = nil
        lastSearch = Date()
        Task {
            try? await a?.stopCapture()
            try? await b?.stopCapture()
        }
        setStatus(msg)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            if self.target != nil { self.detach("Capture stopped: \(error.localizedDescription)") }
        }
    }

    // MARK: Menu actions

    func applyFilters() {
        GlassFX.shared.contrast = 1.0
        GlassFX.shared.saturation = 1.0
        GlassFX.shared.useAverage = false
    }
    @objc func toggleTarget(_ sender: NSMenuItem) {
        let v = !UserDefaults.standard.bool(forKey: "avgmode")
        UserDefaults.standard.set(v, forKey: "avgmode")
        sender.title = v ? "Contrast fades to: Average colour" : "Contrast fades to: Backdrop"
        applyFilters()
    }
    @objc func contrastSlid(_ sender: NSSlider) {
        UserDefaults.standard.set(sender.doubleValue, forKey: "contrast")
        applyFilters()
    }
    @objc func saturationSlid(_ sender: NSSlider) {
        UserDefaults.standard.set(sender.doubleValue, forKey: "saturation")
        applyFilters()
    }
    @objc func opacitySlid(_ sender: NSSlider) {
        opacity = sender.doubleValue
        topLayer.opacity = Float(opacity)
    }

    var pw: CGFloat { let v = UserDefaults.standard.double(forKey: "pw"); return v == 0 ? 480 : CGFloat(v) }
    var ph: CGFloat { let v = UserDefaults.standard.double(forKey: "ph"); return v == 0 ? 300 : CGFloat(v) }

    func findApp() -> NSRunningApplication? {
        return NSWorkspace.shared.runningApplications.first { a in
            if a.processIdentifier == getpid() { return false }
            if a.activationPolicy != .regular { return false }
            return isTarget(bid: a.bundleIdentifier ?? "", name: a.localizedName ?? "")
        }
    }

    func axWindowFrame() -> CGRect? {
        guard let w = axWindow() else { return nil }
        var pr: CFTypeRef?
        var sr: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pr) == .success, let p = pr,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sr) == .success, let sv = sr else { return nil }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(sv as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    func axWindow() -> AXUIElement? {
        guard AXIsProcessTrusted(), targetPID != 0 else { return nil }
        let app = AXUIElementCreateApplication(targetPID)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let wins = ref as? [AXUIElement] else { return nil }
        var mref: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &mref) == .success, let m = mref, CFGetTypeID(m) == AXUIElementGetTypeID() {
            return (m as! AXUIElement)
        }
        return wins.first
    }

    func anchorPoint(width: CGFloat) -> CGPoint? {
        guard let bw = statusItem.button?.window else { return nil }
        let f = bw.frame
        let H = NSScreen.screens.first?.frame.height ?? 0
        var x = f.midX - width / 2
        if let sc = bw.screen {
            x = min(max(x, sc.frame.minX + 8), sc.frame.maxX - width - 8)
        }
        return CGPoint(x: x, y: H - f.minY + 4)
    }

    func windowOrigin(for size: CGSize) -> CGPoint {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let ud = UserDefaults.standard
        if let x = ud.object(forKey: posKey("wx")) as? Double, let y = ud.object(forKey: posKey("wy")) as? Double {
            let r = CGRect(x: x, y: y, width: size.width, height: size.height)
            let visible = NSScreen.screens.contains { sc in
                let cg = CGRect(x: sc.frame.minX, y: primaryH - sc.frame.maxY, width: sc.frame.width, height: sc.frame.height)
                let i = cg.intersection(r)
                return !i.isNull && i.width > 100 && i.height > 60
            }
            if visible { return CGPoint(x: x, y: y) }
        }
        let m = NSEvent.mouseLocation
        let sc = NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        return CGPoint(x: sc.frame.minX + (sc.frame.width - size.width) / 2,
                       y: primaryH - sc.frame.maxY + (sc.frame.height - size.height) / 2)
    }

    func clickedAt(_ p: NSPoint) {
        guard panelShown, !keepOpen, !placing, Date().timeIntervalSince(shownAt) > 0.5 else { return }
        if nsFrame(lastBounds).contains(p) { return }
        if let bw = statusItem.button?.window, bw.frame.insetBy(dx: -4, dy: -4).contains(p) { return }
        hidePanel()
    }

    var fullMode: Bool { (UserDefaults.standard.object(forKey: "full") as? Bool) ?? true }

    func placeUnderIcon() {
        Task { @MainActor in await self.placePanel() }
    }

    func placePanel() async {
        guard let w = axWindow() else { return }
        placing = true
        defer { placing = false }
        AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(w, "AXFullScreen" as CFString, &ref) == .success,
           (ref as? NSNumber)?.boolValue == true {
            // leave macOS fullscreen so the window stays on the current desktop
            AXUIElementSetAttributeValue(w, "AXFullScreen" as CFString, kCFBooleanFalse)
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                var r2: CFTypeRef?
                if AXUIElementCopyAttributeValue(w, "AXFullScreen" as CFString, &r2) == .success,
                   (r2 as? NSNumber)?.boolValue == false { break }
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        var sz = CGSize(width: pw, height: ph)
        var pt = CGPoint.zero
        let sc = statusItem.button?.window?.screen ?? NSScreen.main
        if fullMode, let sc = sc {
            let top = sc.frame.maxY - sc.visibleFrame.maxY
            sz = CGSize(width: sc.frame.width, height: sc.frame.height - top)
            pt = CGPoint(x: sc.frame.minX, y: primaryH - sc.frame.maxY + top)
        }
        if let v = AXValueCreate(.cgSize, &sz) {
            AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v)
        }
        if !fullMode {
            var actual = sz
            var r3: CFTypeRef?
            if AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &r3) == .success,
               let r = r3, CFGetTypeID(r) == AXValueGetTypeID() {
                AXValueGetValue(r as! AXValue, .cgSize, &actual)
            }
            pt = windowOrigin(for: actual)
        }
        if let v = AXValueCreate(.cgPoint, &pt) {
            AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v)
        }
    }

    func showPanel() {
        if !AXIsProcessTrusted() && !askedAX {
            askedAX = true
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        panelShown = true
        shownAt = Date()
        lastSearch = Date.distantPast
        if let a = findApp() {
            targetPID = a.processIdentifier
            a.unhide()
            Task { @MainActor in
                await self.placePanel()
                self.shownAt = Date()
                a.activate(options: [.activateIgnoringOtherApps])
            }
        } else {
            setStatus("Starting \(targetName)…")
            openTarget()
        }
    }

    func hidePanel() {
        panelShown = false
        overlay?.orderOut(nil)
        if targetPID != 0, let a = NSRunningApplication(processIdentifier: targetPID) {
            a.hide()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                if !a.isHidden, !self.panelShown, let w = self.axWindow() {
                    AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                }
            }
        }
    }

    func openTarget() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: targetBundle) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func appActivated(_ pid: pid_t) {
        guard panelShown, !placing, !keepOpen, targetPID != 0, pid != 0, pid != targetPID, pid != getpid(),
              Date().timeIntervalSince(shownAt) > 0.6 else { return }
        hidePanel()
    }

    func rebuildTargetMenu() {
        guard let sub = targetItem.submenu else { return }
        sub.removeAllItems()
        targetItem.title = "Target: \(targetName)"
        if let f = NSWorkspace.shared.frontmostApplication, f.processIdentifier != getpid(), let bid = f.bundleIdentifier {
            let nm = f.localizedName ?? bid
            let it = NSMenuItem(title: "Use frontmost app (\(nm))", action: #selector(pickApp(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = [bid, nm]
            sub.addItem(it)
            sub.addItem(.separator())
        }
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        for a in apps {
            let bid = a.bundleIdentifier ?? ""
            let nm = a.localizedName ?? bid
            let it = NSMenuItem(title: nm, action: #selector(pickApp(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = [bid, nm]
            it.state = bid == targetBundle ? .on : .off
            sub.addItem(it)
        }
        sub.addItem(.separator())
        let ch = NSMenuItem(title: "Choose app…", action: #selector(chooseApp), keyEquivalent: "")
        ch.target = self
        sub.addItem(ch)
        menu.items.first { $0.action == #selector(openRoblox) }?.title = "Open \(targetName)"
    }

    func setTarget(bundle: String, name: String) {
        if panelShown { hidePanel() }
        detach("Click the icon to open \(name)")
        targetPID = 0
        targetBundle = bundle
        targetName = name
        UserDefaults.standard.set(bundle, forKey: "tbid")
        UserDefaults.standard.set(name, forKey: "tname")
        rebuildTargetMenu()
    }

    @objc func pickApp(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? [String], a.count == 2 else { return }
        setTarget(bundle: a[0], name: a[1])
    }

    @objc func chooseApp() {
        let p = NSOpenPanel()
        p.allowedFileTypes = ["app"]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let url = p.url, let b = Bundle(url: url), let bid = b.bundleIdentifier {
            let nm = (b.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
            setTarget(bundle: bid, name: nm)
        }
    }

    @objc func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            rebuildTargetMenu()
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else if panelShown {
            hidePanel()
        } else {
            showPanel()
        }
    }

    func setPanelSize(_ w: CGFloat, _ h: CGFloat) {
        UserDefaults.standard.set(false, forKey: "full")
        UserDefaults.standard.set(Double(w), forKey: "pw")
        UserDefaults.standard.set(Double(h), forKey: "ph")
        if panelShown { placeUnderIcon() }
    }

    @objc func sizeFull() {
        UserDefaults.standard.set(true, forKey: "full")
        if panelShown { placeUnderIcon() }
    }
    @objc func sizeMini() { setPanelSize(240, 150) }
    @objc func sizeTiny() { setPanelSize(340, 212) }
    @objc func sizeSmall() { setPanelSize(480, 300) }
    @objc func sizeMedium() { setPanelSize(640, 400) }
    @objc func toggleKeepOpen(_ sender: NSMenuItem) {
        keepOpen.toggle()
        sender.state = keepOpen ? .on : .off
    }
    @objc func openRoblox() { openTarget() }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
