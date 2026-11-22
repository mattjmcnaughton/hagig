import AppKit
import AVFoundation
import Combine
import SwiftUI
import HagigPresentation
import ServiceManagement

@MainActor
final class ShellDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let presentation = Presentation()
    private var demoWindow: NSWindow!
    private var escapeMonitor: Any?
    private var stageObserver: AnyCancellable?
    /// Record was chosen while microphone access was undecided, so macOS will
    /// show its prompt for this request, which closes the transient popover.
    private var microphonePromptExpected = false
    private let synthetic = CommandLine.arguments.contains("--synthetic-demo")
    private let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/hagig")
    private lazy var dictation = DictationController(presentation: presentation, helper: helper)
    /// Models and settings through the paired helper; nil-run without one.
    private lazy var preferences = Preferences(run: synthetic || !FileManager.default.isExecutableFile(atPath: helper.path)
        ? nil : Preferences.helper(helper))
    private var pageObserver: AnyCancellable?
    /// The one hosted surface. It lives in the popover, or in the shortcut
    /// panel while a shortcut-started request is shown there; never both.
    private var surface: NSHostingController<HagigView>!
    /// The registered record and cancel chords, named in the panel's hint.
    private var registered: PanelShortcuts?
    private let panel = ShortcutPanel(contentRect: NSRect(x: 0, y: 0, width: 330, height: 200),
                                      styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: true)
    private var panelShown = false
    /// The frontmost application when a shortcut started the request.
    private var previousApp: NSRunningApplication?
    private var gesture = ShortcutGesture()
    private var shortcuts: GlobalShortcuts?
    /// Invalidates a pending timed hide.
    private var hideGeneration = 0
    private var settingsObserver: AnyCancellable?
    private var copyObserver: AnyCancellable?
    private var sizeObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        let surface = NSHostingController(rootView:
            HagigView(presentation: presentation,
                      // Setup instructions name the paired helper only when it exists.
                      setup: SetupGuide(helperPath: FileManager.default.isExecutableFile(atPath: helper.path)
                          ? helper.path : nil),
                      preferences: preferences,
                      loginItem: synthetic ? LoginItem.inert : Self.loginItem,
                      record: { [weak self] in
                          guard let self else { return }
                          if synthetic {
                              presentation.begin()
                          } else {
                              let undecided = AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
                              dictation.record()
                              // Set after record(): reserving a request passes through Ready first.
                              microphonePromptExpected = undecided && presentation.stage == .awaitingAdmission
                          }
                      }, stop: { [weak self] in
                          guard let self else { return }
                          if synthetic { presentation.release() } else { dictation.stop() }
                      }, cancel: { [weak self] in
                          guard let self else { return }
                          if synthetic { presentation.cancel() } else { dictation.cancel() }
                      }, copy: Self.copy)
        )
        // The popover takes its size from the view through preferredContentSize,
        // which keeps it attached to the menu-bar item as states change height.
        // Left to resize its own window, the hosting view built with the macOS 26
        // SDK grows upward from a fixed bottom edge, over the menu bar.
        surface.sizingOptions = .preferredContentSize
        popover.contentViewController = surface
        self.surface = surface
        // Handle active cancellation before normal popover key processing.
        // Only events delivered to this app, and never review-mode Escape.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53,
                  [.awaitingAdmission, .recording, .transcribing].contains(presentation.stage) else { return event }
            if synthetic { presentation.cancel() } else { dictation.cancel() }
            return nil
        }
        // The menu-bar item is the only sign of work while the popover is closed.
        // @Published delivers the new stage before storing it. Reflect it one
        // main-queue turn later: AppKit work done before the value is stored made
        // macOS 26 render the popover with the old stage and never again, leaving
        // "Ready" on screen after a failure. Stages still arrive in order.
        stageObserver = presentation.$stage.receive(on: DispatchQueue.main)
            .sink { [weak self] stage in self?.reflect(stage) }
        // Leaving setup after a model or settings problem returns to Ready: the
        // problem was what the user just went to fix, and Record retries it.
        pageObserver = preferences.$page.receive(on: DispatchQueue.main).sink { [weak self] page in
            guard let self, page == nil,
                  [.issue(.configuration), .issue(.modelMissing)].contains(presentation.stage) else { return }
            presentation.reset()
        }
        // Explicit test/demo mode is never selected by a backend/capture failure.
        guard synthetic else {
            startShortcuts()
            return
        }
        demoWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        demoWindow.title = "Hagig · Demo controls"
        demoWindow.isReleasedWhenClosed = false
        let demoController = NSHostingController(rootView:
            DemoControls(presentation: presentation, showPopover: showPopover)
        )
        demoWindow.contentViewController = demoController
        demoWindow.setContentSize(demoController.view.fittingSize)
        demoWindow.center()
        demoWindow.makeKeyAndOrderFront(nil)
        // Activate only the explicit demo harness, never an intended destination.
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        // The same surface, in the same state, moves back from the panel.
        hidePanel(returnFocus: false)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    /// The user opened Hagig's own surface: take the keyboard so Return, Escape
    /// and the review editor work at once. Never used for the demo harness, and
    /// never activates any other application.
    private func showPopoverForKeyboard() {
        showPopover()
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func reflect(_ stage: DemoStage) {
        followPanel()
        let symbol: String, state: String
        switch stage {
        case .ready, .cancelled, .noSpeech: (symbol, state) = ("mic", "Ready")
        case .awaitingAdmission: (symbol, state) = ("mic", "Preparing to record")
        case .recording: (symbol, state) = ("mic.fill", "Recording")
        case .transcribing: (symbol, state) = ("waveform", "Transcribing")
        case .fallback: (symbol, state) = ("text.cursor", "Transcript ready to review")
        case .issue: (symbol, state) = ("exclamationmark.triangle", "Needs attention")
        }
        let name = synthetic ? "Hagig synthetic demo" : "Hagig"
        var image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
        if stage == .recording {
            // Template images take the menu bar's colour; recording is the one
            // state drawn in the system red instead.
            image = image?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
            image?.isTemplate = false
        }
        statusItem.button?.image = image
        statusItem.button?.setAccessibilityValue(state)
        statusItem.button?.toolTip = synthetic ? "Hagig synthetic demo: \(state). Right-click for demo controls."
            : "Hagig: \(state). Right-click to quit."
        // The macOS microphone prompt closes the transient popover. Only for the
        // request that showed it, bring back what the user's answer led to: Stop
        // after Allow, or the way to System Settings after Don't Allow. A popover
        // closed any other way was the user's choice, perhaps to work in another
        // application, and nothing here reopens it or takes focus.
        // Every transition passes through Ready (`Presentation.reset`), so only
        // a settled stage answers or abandons the expectation.
        guard stage != .awaitingAdmission, stage != .ready else { return }
        let answered = stage == .recording || stage == .issue(.microphonePermission)
        let reopen = microphonePromptExpected && answered && !popover.isShown && !panelShown
        microphonePromptExpected = false
        if reopen {
            DispatchQueue.main.async { [weak self] in
                guard let self, presentation.stage == stage, !popover.isShown else { return }
                showPopoverForKeyboard()
            }
        }
    }

    @objc private func togglePopover() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(nil)
            if synthetic {
                demoWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else if let button = statusItem.button {
                let menu = NSMenu()
                let quit = menu.addItem(withTitle: "Quit Hagig", action: #selector(ShellDelegate.quit), keyEquivalent: "")
                quit.target = self
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
            }
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else if synthetic {
            showPopover()
        } else {
            showPopoverForKeyboard()
        }
    }

    private static func copy(_ text: String) -> Bool {
        LocalClipboard().write(text)
    }

    /// Open at login through ServiceManagement, applied at once from Settings.
    private static var loginItem: LoginItem {
        LoginItem(status: {
            switch SMAppService.mainApp.status {
            case .enabled: return .enabled
            case .requiresApproval: return .requiresApproval
            default: return .disabled
            }
        }, set: { on in
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                return true
            } catch {
                return false
            }
        }, openSettings: { SMAppService.openSystemSettingsLoginItems() })
    }

    // MARK: Global shortcuts and the shortcut panel

    private func startShortcuts() {
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // HagigView paints no background; the panel supplies the system
        // material, as the popover does.
        let backdrop = NSVisualEffectView()
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 12
        backdrop.layer?.masksToBounds = true
        panel.contentView = backdrop

        shortcuts = GlobalShortcuts { [weak self] name, pressed in self?.shortcut(name, pressed: pressed) }
        // Defaults until the settings file is read; they stay if it cannot be.
        applyShortcuts(nil)
        settingsObserver = preferences.$settingsRevision.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                applyShortcuts(preferences.settings)
            }
        copyObserver = presentation.$copied.receive(on: DispatchQueue.main).sink { [weak self] copied in
            if copied { self?.copiedInPanel() }
        }
        sizeObserver = surface.publisher(for: \.preferredContentSize).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.fitPanel(placing: false) }
        preferences.loadSettings()
    }

    /// Registers the settings file's shortcuts, or the default for any that is
    /// missing or invalid (or when the file does not load). Settings shows a
    /// chord another app holds.
    private func applyShortcuts(_ settings: StoredSettings?) {
        guard let shortcuts,
              let record = settings.flatMap({ Shortcut($0.recordShortcut) }) ?? Shortcut(Shortcut.defaultRecord),
              let cancel = settings.flatMap({ Shortcut($0.cancelShortcut) }) ?? Shortcut(Shortcut.defaultCancel)
        else { return }
        let failed = shortcuts.register(record: record, cancel: cancel)
        registered = PanelShortcuts(record: record.display, cancel: cancel.display)
        if panelShown { surface.rootView = surface.rootView.inPanel(registered) }
        preferences.report(shortcutIssue: failed.isEmpty ? nil
            : failed.map(\.display).joined(separator: " and ")
                + (failed.count == 1 ? " is" : " are") + " in use by another app")
    }

    private func shortcut(_ name: ShortcutName, pressed: Bool) {
        let stage = presentation.stage
        switch name {
        case .cancel:
            if pressed, [.awaitingAdmission, .recording, .transcribing].contains(stage) { dictation.cancel() }
        case .record:
            let phase: ShortcutGesture.Phase
            switch stage {
            case .ready, .cancelled, .noSpeech: phase = .idle
            case .awaitingAdmission: phase = .preparing
            case .recording: phase = .recording
            default: phase = .other // Transcribing, review or an issue: never lose text.
            }
            let now = ProcessInfo.processInfo.systemUptime
            switch pressed ? gesture.press(at: now, phase: phase) : gesture.release(at: now, phase: phase) {
            case .start: startFromShortcut()
            case .stop: dictation.stop()
            case .cancel: dictation.cancel()
            case .nothing: break
            }
        }
    }

    /// The Record button's path, shown in the panel instead of the popover.
    private func startFromShortcut() {
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == NSRunningApplication.current.processIdentifier ? nil : front
        // The panel covers the microphone prompt's case; never reopen the popover.
        microphonePromptExpected = false
        preferences.close()
        showPanel()
        dictation.record()
    }

    private func showPanel() {
        hideGeneration += 1
        if popover.isShown { popover.close() }
        if !panelShown, let backdrop = panel.contentView {
            // Detach from the popover before attaching here: one live surface,
            // so the review editor and its presentation binding stay single.
            popover.contentViewController = nil
            surface.view.removeFromSuperview()
            surface.view.translatesAutoresizingMaskIntoConstraints = true
            surface.view.frame = backdrop.bounds
            surface.view.autoresizingMask = [.width, .height]
            backdrop.addSubview(surface.view)
            panelShown = true
            surface.rootView = surface.rootView.inPanel(registered)
            fitPanel(placing: true)
        }
        panel.orderFrontRegardless()
    }

    /// Follows the newest stage. Active work never takes the keyboard; review
    /// and issues do, without activating Hagig.
    private func followPanel() {
        guard panelShown else { return }
        let stage = presentation.stage
        switch stage {
        case .awaitingAdmission, .recording, .transcribing:
            panel.orderFrontRegardless()
        case .fallback, .issue:
            panel.makeKeyAndOrderFront(nil)
        case .cancelled, .noSpeech:
            panel.orderFrontRegardless()
            hideGeneration += 1
            let generation = hideGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, hideGeneration == generation, presentation.stage == stage else { return }
                hidePanel()
            }
        case .ready:
            hidePanel()
        }
    }

    /// Copy all succeeded in the panel: the text is on this Mac's clipboard, so
    /// close, discard the review and give the keys back.
    private func copiedInPanel() {
        guard panelShown, presentation.stage == .fallback, presentation.copied else { return }
        hidePanel()
        presentation.reset()
    }

    private func hidePanel(returnFocus: Bool = true) {
        guard panelShown else { return }
        let wasKey = panel.isKeyWindow
        panelShown = false
        hideGeneration += 1
        panel.orderOut(nil)
        surface.view.removeFromSuperview()
        surface.rootView = surface.rootView.inPanel(nil)
        popover.contentViewController = surface
        let previous = previousApp
        previousApp = nil
        // Only after the panel took the keyboard, and only back to the app the
        // shortcut was pressed in, if it lost them. Never any other app.
        guard returnFocus, wasKey, let previous, !previous.isTerminated,
              NSApp.isActive || NSWorkspace.shared.frontmostApplication?.processIdentifier != previous.processIdentifier
        else { return }
        if #available(macOS 14, *) {
            NSApp.yieldActivation(to: previous)
            previous.activate()
        } else {
            previous.activate(options: [])
        }
    }

    /// Sized by the surface, like the popover; placed near the top centre of
    /// the screen with the pointer, and kept there by its top edge.
    private func fitPanel(placing: Bool) {
        guard panelShown else { return }
        var size = surface.preferredContentSize
        if size.width < 1 || size.height < 1 { size = surface.view.fittingSize }
        guard size.width >= 1, size.height >= 1 else { return }
        let frame: NSRect
        if placing {
            let mouse = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
            else { return }
            let visible = screen.visibleFrame
            frame = NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 12,
                           width: size.width, height: size.height)
        } else {
            frame = NSRect(x: panel.frame.minX, y: panel.frame.maxY - size.height,
                           width: size.width, height: size.height)
        }
        panel.setFrame(frame, display: true)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        if !synthetic { dictation.cancel() }
        // An install the user started stops with the app; its earlier model stays.
        preferences.cancelDownload()
    }
}

/// Simulation stays outside the production-facing popover. Only its Copy button
/// writes to the clipboard; these controls never deliver a synthetic result.
@MainActor
private struct DemoControls: View {
    @ObservedObject var presentation: Presentation
    let showPopover: () -> Void
    @State private var demoMode = EditorMode.standard

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Synthetic demo", systemImage: "flask").font(.headline)
            Text("No microphone, inference, global shortcut, or automatic paste. All results are synthetic. Only explicit Copy in the popover writes to this Mac’s clipboard.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Right-click the menu-bar microphone to reopen these controls.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Synthetic editor mode (not TOML)", selection: $demoMode) {
                Text("Standard").tag(EditorMode.standard)
                Text("Bounded Vim").tag(EditorMode.vim)
            }
            .accessibilityIdentifier("synthetic-editor-mode")
            Button("Show menu-bar surface", action: showPopover)
            HStack {
                Button("Simulate recording") { presentation.begin(editorMode: demoMode); showPopover() }
                    .disabled(presentation.stage == .recording || presentation.stage == .transcribing)
                Button("Simulate release") { presentation.release(); showPopover() }
                    .disabled(presentation.stage != .recording)
            }
            Button("Simulate result") {
                if let id = presentation.requestID {
                    presentation.complete(requestID: id, text: Presentation.fixture)
                    showPopover()
                }
            }.disabled(presentation.stage != .transcribing)
            HStack {
                Menu("Preview error") {
                    ForEach(DemoIssue.allCases, id: \.self) { issue in
                        Button(issue.title) { presentation.show(issue: issue); showPopover() }
                    }
                }
                Button("Reset") { presentation.reset(); showPopover() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            Text("No app-maintained transcript history. Local clipboard managers may retain copied text.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(width: 380)
        .onExitCommand {
            if presentation.stage == .recording || presentation.stage == .transcribing { presentation.cancel() }
        }
    }
}

@main
struct Shell {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = ShellDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
