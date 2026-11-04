import AppKit
import MetalKit
import ScreenCaptureKit
import CoreMedia
import Carbon
import Darwin

private let duration = 1.65
private let maxRipples = 24

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class TransparentView: MTKView {
    override var isOpaque: Bool { false }
}

struct Ripple {
    let point: CGPoint
    let end: CGPoint
    let birth: Double
    let wake: Bool
    var lifetime: Double { wake ? 1.2 : duration }
}

final class Surface: NSObject, MTKViewDelegate, SCStreamOutput, SCStreamDelegate {
    let screen: NSScreen
    let window: OverlayWindow
    let view: TransparentView
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var cache: CVMetalTextureCache!
    private var stream: SCStream?
    private var source: CVPixelBuffer?
    private var mappedTexture: CVMetalTexture?
    private var ripples: [Ripple] = []
    private var idleTimer: Timer?
    private var loggedPresentation = false
    private let display: SCDisplay
    private var filter: SCContentFilter?
    private let config: SCStreamConfiguration
    var reportError: ((Error) -> Void)?
    var style = SIMD4<Float>(1, 0, 0, 0)

    init(screen: NSScreen, display: SCDisplay,
         device: MTLDevice, pipeline: MTLRenderPipelineState) throws {
        self.screen = screen
        self.display = display
        self.device = device
        self.pipeline = pipeline
        guard let queue = device.makeCommandQueue() else { throw AppError.message("Metal command queue unavailable.") }
        self.queue = queue
        config = SCStreamConfiguration()
        config.width = Int(screen.frame.width * screen.backingScaleFactor)
        config.height = Int(screen.frame.height * screen.backingScaleFactor)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = false
        config.scalesToFit = true
        view = TransparentView(frame: NSRect(origin: .zero, size: screen.frame.size), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.isPaused = true
        window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless,
                               backing: .buffered, defer: false, screen: screen)
        window.setFrame(screen.frame, display: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        window.isReleasedWhenClosed = false
        window.contentView = view
        super.init()
        view.delegate = self
        view.layer?.isOpaque = false
        let result = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard result == kCVReturnSuccess else { throw AppError.message("Metal texture cache unavailable.") }
    }

    func prepareFilter(excluding windows: [SCWindow]) {
        filter = SCContentFilter(display: display, excludingWindows: windows)
    }

    func add(at point: CGPoint) {
        add(from: point, to: point, wake: false)
    }

    func add(from start: CGPoint, to end: CGPoint, wake: Bool) {
        let now = CACurrentMediaTime()
        ripples.removeAll { now - $0.birth >= $0.lifetime }
        if ripples.count >= maxRipples { ripples.removeFirst() }
        ripples.append(Ripple(point: CGPoint(x: start.x - screen.frame.minX,
                                             y: screen.frame.maxY - start.y),
                              end: CGPoint(x: end.x - screen.frame.minX,
                                           y: screen.frame.maxY - end.y),
                              birth: now, wake: wake))
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: duration + 0.05, repeats: false) { [weak self] _ in
            self?.stop()
        }
        if stream == nil { self.start() }
    }

    private func start() {
        guard let filter else { return }
        let next = SCStream(filter: filter, configuration: config, delegate: self)
        stream = next
        do {
            try next.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
        } catch { fail(error, for: next); return }
        Task { @MainActor [weak self] in
            do {
                try await next.startCapture()
                if self?.stream !== next { try? await next.stopCapture() }
            } catch { self?.fail(error, for: next) }
        }
    }

    private func fail(_ error: Error, for failed: SCStream) {
        guard stream === failed else { return }
        stop()
        reportError?(error)
    }

    func stop() {
        idleTimer?.invalidate()
        idleTimer = nil
        view.isPaused = true
        window.orderOut(nil)
        ripples.removeAll(keepingCapacity: true)
        source = nil
        mappedTexture = nil
        if let previous = stream {
            stream = nil
            Task { try? await previous.stopCapture() }
        }
        if let cache { CVMetalTextureCacheFlush(cache, 0) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.fail(error, for: stream) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard self.stream === stream, type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              let image = sample.imageBuffer else { return }
        var mapped: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(nil, cache, image, nil, .bgra8Unorm,
                            CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image), 0, &mapped)
        guard result == kCVReturnSuccess, let mapped else { return }
        source = image
        mappedTexture = mapped
        if view.isPaused {
            // Start time at the first available frame so capture startup doesn't
            // eat the first ripple on a cold start.
            let now = CACurrentMediaTime()
            ripples = ripples.map { Ripple(point: $0.point, end: $0.end, birth: now, wake: $0.wake) }
            idleTimer?.invalidate()
            idleTimer = Timer.scheduledTimer(withTimeInterval: duration + 0.05, repeats: false) { [weak self] _ in self?.stop() }
            window.orderFrontRegardless()
            view.isPaused = false
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        ripples.removeAll { now - $0.birth >= $0.lifetime }
        guard !ripples.isEmpty else { stop(); return }
        guard let mappedTexture, let source,
              let texture = CVMetalTextureGetTexture(mappedTexture),
              let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let command = queue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        var appearance = style
        appearance.w = Float(now)
        var uniforms = [SIMD4<Float>(Float(screen.frame.width), Float(screen.frame.height), Float(ripples.count), 1), appearance]
        var bounds = CGRect.null
        for ripple in ripples {
            let age = now - ripple.birth
            uniforms.append(SIMD4<Float>(Float(ripple.point.x), Float(ripple.point.y), Float(age), ripple.wake ? 1 : 0))
            uniforms.append(SIMD4<Float>(Float(ripple.end.x), Float(ripple.end.y), 0, 0))
            let baseExtent = ripple.wake ? 3 + age * 65 + (10 + age * 10) * 5
                                         : 18 + age * 290 + (13 + age * 8) * 5
            let extent = baseExtent * Double(style.x) * 1.5
            bounds = bounds.union(CGRect(x: ripple.point.x - extent, y: ripple.point.y - extent,
                                         width: extent * 2, height: extent * 2))
            if ripple.wake {
                bounds = bounds.union(CGRect(x: ripple.end.x - extent, y: ripple.end.y - extent,
                                             width: extent * 2, height: extent * 2))
            }
        }
        while uniforms.count < maxRipples * 2 + 2 { uniforms.append(.zero) }
        let sx = CGFloat(drawable.texture.width) / screen.frame.width
        let sy = CGFloat(drawable.texture.height) / screen.frame.height
        let clipped = bounds.intersection(CGRect(origin: .zero, size: screen.frame.size))
        if !clipped.isNull && !clipped.isEmpty {
            let x = max(0, Int(floor(clipped.minX * sx)))
            let y = max(0, Int(floor(clipped.minY * sy)))
            let right = min(drawable.texture.width, Int(ceil(clipped.maxX * sx)))
            let bottom = min(drawable.texture.height, Int(ceil(clipped.maxY * sy)))
            encoder.setScissorRect(MTLScissorRect(x: x, y: y, width: right - x, height: bottom - y))
            encoder.setRenderPipelineState(pipeline)
            uniforms.withUnsafeBytes { bytes in
                encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
            }
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        // Retain the IOSurface-backed frame until the GPU finishes sampling it.
        command.addCompletedHandler { _ in _ = (source, mappedTexture) }
        if !loggedPresentation {
            loggedPresentation = true
            drawable.addPresentedHandler { _ in NSLog("Glass Ripples: first ripple frame presented") }
        }
        command.present(drawable)
        command.commit()
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var enabled = false
    private var configuring = false
    private var surfaces: [Surface] = []
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var device: MTLDevice!
    private var pipeline: MTLRenderPipelineState!
    private var loggedTouch = false
    private var lastTouchPoints: [Int32: CGPoint] = [:]
    private var effectOptions = [1, 0]
    private var effectItems: [NSMenuItem] = []

    private var effectStyle: SIMD4<Float> {
        SIMD4<Float>([0.65, 1, 1.4][effectOptions[0]], 0, Float(effectOptions[1]), 0)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try setupMetal() } catch { show(error); NSApp.terminate(nil); return }
        if let saved = UserDefaults.standard.array(forKey: "effectOptions") as? [Int] {
            if saved.count == 2, (0...2).contains(saved[0]), (0...3).contains(saved[1]) {
                effectOptions = saved
            } else if saved.count == 3, (0...2).contains(saved[0]), (0...3).contains(saved[2]) {
                // Older preferences stored a shape and separate Cool/Warm styles.
                effectOptions = [saved[0], min(saved[2], 2)]
            }
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "water.waves", accessibilityDescription: "Glass Ripples")
        let menu = NSMenu()
        let version = menu.addItem(withTitle: "Glass Ripples 0.4.2 · Touch & Drag", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(.separator())
        toggleItem = menu.addItem(withTitle: "Ripples Enabled   ⌃⌥⌘R", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        let demo = menu.addItem(withTitle: "Test Ripple", action: #selector(testRipple), keyEquivalent: "")
        demo.target = self
        menu.addItem(.separator())
        let choices = [("Ripple Size", ["Small", "Medium", "Large"]),
                       ("Glass Color", ["Natural", "Prism", "Sunset", "Six Colors"])]
        for (group, choice) in choices.enumerated() {
            let parent = menu.addItem(withTitle: choice.0, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: choice.0)
            for (index, title) in choice.1.enumerated() {
                let option = submenu.addItem(withTitle: title, action: #selector(changeEffect(_:)), keyEquivalent: "")
                option.target = self
                option.tag = group * 10 + index
                option.state = effectOptions[group] == index ? .on : .off
                effectItems.append(option)
            }
            parent.submenu = submenu
        }
        menu.addItem(.separator())
        let access = menu.addItem(withTitle: "Screen Recording Settings…", action: #selector(openSettings), keyEquivalent: "")
        access.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Glass Ripples", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        installHotKey()
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged),
                    name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.willSleepNotification, object: nil)
        // First launch explains the OS permission before requesting capture.
        if !UserDefaults.standard.bool(forKey: "introduced") {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Glass ripples over your apps"
            alert.informativeText = "Touch the built-in display to create subtle glass ripples without blocking your apps. Mouse clicks and trackpad touches do not trigger the effect. Toggle with Control–Option–Command–R.\n\nEnable Screen Recording when macOS asks so the ripples can bend the desktop image. Frames stay in memory; nothing is saved or transmitted."
            alert.addButton(withTitle: "Enable Ripples")
            alert.addButton(withTitle: "Later")
            let response = alert.runModal()
            UserDefaults.standard.set(true, forKey: "introduced")
            if response == .alertFirstButtonReturn { toggle() }
        } else { toggle() }
    }

    private func setupMetal() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let url = Bundle.main.url(forResource: "Ripple", withExtension: "metal") else {
            throw AppError.message("Metal or the ripple shader is unavailable.")
        }
        self.device = device
        // Development overrides live outside privacy-protected user folders.
        let editableShader = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassRipples-Ripple.metal")
        let overrideSource = try? String(contentsOf: editableShader, encoding: .utf8)
        let source = try overrideSource ?? String(contentsOf: url, encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fullscreen")
        descriptor.fragmentFunction = library.makeFunction(name: "liquid")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let color = descriptor.colorAttachments[0]!
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    @objc func toggle() {
        guard !configuring else { return }
        if enabled { disable(); return }
        configuring = true
        toggleItem.title = "Preparing Ripples…"
        Task { @MainActor [self] in
            defer { configuring = false; updateMenu() }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                var ready: [Surface] = []
                defer { ready.forEach { $0.window.orderOut(nil) } }
                for screen in NSScreen.screens {
                    guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                          CGDisplayIsBuiltin(id.uint32Value) != 0,
                          let display = content.displays.first(where: { $0.displayID == id.uint32Value }) else { continue }
                    let surface = try Surface(screen: screen, display: display, device: device, pipeline: pipeline)
                    surface.reportError = { [weak self] error in self?.disable(); self?.show(error) }
                    surface.style = effectStyle
                    ready.append(surface)
                }
                guard ready.count == 1 else { throw AppError.message("Open the built-in display to enable touch ripples.") }
                // Menu-bar apps may be absent from SCShareableContent.applications.
                // Register the actual transparent overlay windows first, then
                // exclude their window IDs instead of depending on an app entry.
                ready.forEach { $0.window.orderFrontRegardless() }
                let ids = Set(ready.map { CGWindowID($0.window.windowNumber) })
                var ownWindows: [SCWindow] = []
                for attempt in 0..<3 {
                    let registered = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    ownWindows = registered.windows.filter { ids.contains($0.windowID) }
                    if Set(ownWindows.map(\.windowID)) == ids { break }
                    if attempt < 2 { try await Task.sleep(nanoseconds: 100_000_000) }
                }
                guard Set(ownWindows.map(\.windowID)) == ids else {
                    throw AppError.message("macOS has not registered the transparent overlay windows for capture yet. Try Enable Ripples again.")
                }
                ready.forEach { $0.prepareFilter(excluding: ownWindows) }
                guard GRStartTouchInput({ x, y, identifier, moving, context in
                    guard let context else { return }
                    Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue().touched(x: x, y: y, identifier: identifier, moving: moving != 0)
                }, Unmanaged.passUnretained(self).toOpaque()) != 0 else {
                    throw AppError.message(String(cString: GRLastTouchError()))
                }
                NSLog("Glass Ripples 0.4.2: built-in touchscreen reader enabled")
                loggedTouch = false
                surfaces = ready
                enabled = true
            } catch { disable(); show(error) }
        }
    }

    private func disable() {
        enabled = false
        lastTouchPoints.removeAll()
        GRStopTouchInput()
        surfaces.forEach { $0.stop() }
        surfaces.removeAll()
        updateMenu()
    }

    private func updateMenu() {
        toggleItem.title = "Ripples Enabled   ⌃⌥⌘R"
        toggleItem.state = enabled ? .on : .off
        item.button?.appearsDisabled = !enabled
    }

    @objc private func changeEffect(_ sender: NSMenuItem) {
        effectOptions[sender.tag / 10] = sender.tag % 10
        UserDefaults.standard.set(effectOptions, forKey: "effectOptions")
        for option in effectItems {
            option.state = effectOptions[option.tag / 10] == option.tag % 10 ? .on : .off
        }
        surfaces.forEach { $0.style = effectStyle }
    }

    private func touched(x: Float, y: Float, identifier: Int32, moving: Bool) {
        guard enabled, let surface = surfaces.first else { return }
        if !loggedTouch {
            loggedTouch = true
            NSLog("Glass Ripples: first physical touchscreen contact received")
        }
        let frame = surface.screen.frame
        let point = CGPoint(x: frame.minX + CGFloat(x) * frame.width,
                            y: frame.minY + CGFloat(y) * frame.height)
        if moving, let previous = lastTouchPoints[identifier] {
            surface.add(from: previous, to: point, wake: true)
        } else {
            surface.add(at: point)
        }
        lastTouchPoints[identifier] = point
    }

    @objc private func testRipple() {
        guard enabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, enabled, let surface = surfaces.first else { return }
            let frame = surface.screen.frame
            surface.add(at: CGPoint(x: frame.midX, y: frame.midY))
        }
    }

    @objc private func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func displaysChanged() {
        let restart = enabled
        disable()
        if restart { toggle() }
    }

    @objc private func sleeping() { surfaces.forEach { $0.stop() } }

    private func show(_ error: Error) {
        NSLog("Glass Ripples error: %@", error.localizedDescription)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Glass Ripples needs attention"
        alert.informativeText = error.localizedDescription + "\n\nIf screen access was denied, allow Glass Ripples in System Settings → Privacy & Security → Screen Recording, then enable ripples again."
        alert.runModal()
    }

    private func installHotKey() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
            guard let data else { return OSStatus(eventNotHandledErr) }
            Unmanaged<AppDelegate>.fromOpaque(data).takeUnretainedValue().toggle()
            return noErr
        }, 1, &event, context, &hotKeyHandler)
        let id = EventHotKeyID(signature: 0x4752504C, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(controlKey | optionKey | cmdKey), id,
                                         GetApplicationEventTarget(), 0, &hotKey)
        if handlerStatus != noErr || status != noErr {
            show(AppError.message("The global shortcut could not be registered. You can toggle ripples from the menu bar."))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        disable()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}

let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("GlassRipples.log")
if let log = fopen(logURL.path, "a") {
    dup2(fileno(log), STDERR_FILENO)
    fclose(log)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
withExtendedLifetime(delegate) {
    app.run()
}
