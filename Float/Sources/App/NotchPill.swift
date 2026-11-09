import AppKit
import SwiftUI

/// Where the pill goes: hugging the built-in display's notch, or a small pill at the top centre
/// of the main screen when no display has one.
struct NotchGeometry: Equatable {
    let screenFrame: NSRect
    let notchWidth: CGFloat
    let height: CGFloat
    let hasNotch: Bool

    static let wing: CGFloat = 34

    static func current() -> NotchGeometry? {
        if let s = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            var w: CGFloat = 190
            if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea { w = s.frame.width - l.width - r.width }
            return NotchGeometry(screenFrame: s.frame, notchWidth: w, height: s.safeAreaInsets.top, hasNotch: true)
        }
        guard let s = NSScreen.main ?? NSScreen.screens.first else { return nil }
        let menuBar = s.frame.maxY - s.visibleFrame.maxY
        return NotchGeometry(screenFrame: s.frame, notchWidth: 36, height: min(max(menuBar, 24), 32), hasNotch: false)
    }

    var pillFrame: NSRect {
        let w = notchWidth + Self.wing * 2
        return NSRect(x: (screenFrame.midX - w / 2).rounded(), y: screenFrame.maxY - height, width: w, height: height)
    }
}

/// The collapsed form of Float: a black pill around the notch, above everything (menu bar and full-screen
/// apps included). Hover, click or the hotkey opens the chat; right-click has the app's menu.
final class NotchWindow: NSPanel {
    let host: NotchHostingView

    init(store: ChatStore) {
        host = NotchHostingView(rootView: AnyView(NotchPillView().environment(store)))
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 32),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        canHide = false  // NSApp.hide (after the panel closes) must leave the pill in place
        animationBehavior = .none
        isReleasedWhenClosed = false
        host.sizingOptions = []
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func place() {
        guard let g = NotchGeometry.current() else { return }
        setFrame(g.pillFrame, display: true)
        NotchState.shared.geometry = g
    }
}

final class NotchHostingView: NSHostingView<AnyView> {
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    var menuProvider: (() -> NSMenu)?
    private var area: NSTrackingArea?

    required init(rootView: AnyView) { super.init(rootView: rootView) }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { NotchState.shared.hovering = true; onHover?(true) }
    override func mouseExited(with event: NSEvent) { NotchState.shared.hovering = false; onHover?(false) }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
    override func rightMouseDown(with event: NSEvent) {
        if let m = menuProvider?() { NSMenu.popUpContextMenu(m, with: event, for: self) }
    }
}

@Observable
final class NotchState {
    static let shared = NotchState()
    var geometry: NotchGeometry?
    var hovering = false
    var expanded = false
}

/// Lets AppKit code (the pill's menu) open the SwiftUI Settings scene.
enum SettingsOpener {
    @MainActor static var action: (() -> Void)?
    @MainActor static func open() {
        NSApp.activate()
        action?()
    }
}

/// Builds NSMenu items that run closures.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command], checked: Bool = false, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
        state = checked ? .on : .off
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}

/// What the pill shows: a quiet glyph on the left and live activity on the right.
struct NotchPillView: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @State private var notch = NotchState.shared

    private enum Activity { case idle, listening, thinking, speaking }

    private var activity: Activity {
        let voice = store.voice
        if voice.isListening { return .listening }
        if voice.phase == .speaking { return .speaking }
        if store.isBusy || voice.phase == .waiting { return .thinking }
        return .idle
    }

    var body: some View {
        let g = notch.geometry
        let radius: CGFloat = (g?.height ?? 32) * 0.36
        HStack(spacing: 0) {
            leading.frame(width: NotchGeometry.wing)
            Spacer(minLength: 0)
            trailing.frame(width: NotchGeometry.wing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)
                .fill(.black)
        )
        .scaleEffect(notch.hovering && !notch.expanded ? 1.04 : 1, anchor: .top)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: notch.hovering)
        .animation(.snappy(duration: 0.25), value: activity)
        .onAppear {
            SettingsOpener.action = { openSettings() }
            if ProcessInfo.processInfo.environment["FLOAT_OPEN_SETTINGS"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { SettingsOpener.open() }
            }
        }
    }

    @ViewBuilder private var leading: some View {
        Group {
            switch activity {
            case .listening:
                Image(systemName: "mic.fill").foregroundStyle(.red)
            case .speaking:
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.white)
            case .thinking:
                Image(systemName: "sparkle").foregroundStyle(.white.opacity(0.9))
                    .symbolEffect(.pulse, isActive: true)
            case .idle:
                Image(systemName: "bolt.horizontal.circle.fill").foregroundStyle(.white.opacity(notch.hovering ? 0.9 : 0.55))
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .transition(.opacity.combined(with: .scale(scale: 0.7)))
    }

    @ViewBuilder private var trailing: some View {
        switch activity {
        case .listening: PillBars(color: .red, level: Double(store.voice.level))
        case .speaking: PillBars(color: .white, level: nil)
        case .thinking: PillDots()
        case .idle:
            if store.needsAttention && Preferences.shared.menuBarBadge {
                Circle().fill(Color.orange).frame(width: 6, height: 6)
            }
        }
    }
}

/// Four little bars: follow the mic level when there is one, otherwise a gentle wave.
private struct PillBars: View {
    let color: Color
    let level: Double?

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let wave = (sin(t * 7 + Double(i) * 1.3) + 1) / 2
                    let amp = level.map { min(1, max(0.15, $0 * 3)) } ?? 0.8
                    Capsule().fill(color)
                        .frame(width: 2.5, height: 4 + 9 * wave * amp)
                }
            }
        }
        .frame(height: 14)
    }
}

/// Three dots breathing in turn while Hermes thinks.
private struct PillDots: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(.white)
                        .frame(width: 4, height: 4)
                        .opacity(0.3 + 0.7 * (sin(t * 5 - Double(i) * 0.9) + 1) / 2)
                }
            }
        }
    }
}
