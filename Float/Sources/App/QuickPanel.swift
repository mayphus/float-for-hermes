import AppKit
import Quartz
import SwiftUI

/// Observable bit the SwiftUI tree uses to run its own entrance/exit animation.
@Observable
final class PanelPresentation {
    var isPresented = false
    var focusToken = 0
    /// Set by the controller: refit the window to the card's saved size.
    @ObservationIgnored var refit: () -> Void = {}
    /// The card's frame in the window (top-left origin), so the notch can tell when the mouse has left it.
    @ObservationIgnored var cardFrame: CGRect = .zero
}

/// A borderless, transparent floating panel (Spotlight-style). The window is fixed-size and
/// fully transparent; SwiftUI draws and animates the glass card inside it, and clicks on the
/// transparent margin fall through to whatever is underneath.
final class QuickPanel: NSPanel {
    var onCancel: (() -> Void)?

    init(content: some View) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.fittingSize()),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .none
        isReleasedWhenClosed = false

        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        contentView = host
    }

    /// The transparent window is the card plus room for its shadow, the error pill and cards that grow
    /// the content; the message list shrinks to fit before anything can overflow (see QuickChatView).
    static func fittingSize() -> NSSize {
        let prefs = Preferences.shared
        return NSSize(width: prefs.effectivePanelWidth + 80, height: prefs.listHeight + 280)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let ok = super.makeFirstResponder(responder)
        if let editor = firstResponder as? NSTextView, editor.isFieldEditor { FieldEditorDrops.adopt(editor) }
        return ok
    }

    // Quick Look (double-clicking a sent image) asks the key window's responder chain who drives it.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { ImagePreview.shared.hasItems }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { ImagePreview.shared.begin(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { ImagePreview.shared.end(panel) }
}

/// The pinned form of Float: a regular, resizable window at normal level. It ignores Esc and
/// focus loss, shows the app in the Dock while open, and remembers its frame across launches.
final class PinnedWindow: NSWindow {
    init(content: some View) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
                   styleMask: [.borderless, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "Float"
        // Borderless and shadowless: the card's own glass is the whole window, with no system rim or
        // rectangular shadow edge peeking out around its rounded corners.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        level = .normal
        collectionBehavior = [.managed, .fullScreenPrimary]
        minSize = NSSize(width: 380, height: 320)

        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        contentView = host
        if !setFrameUsingName(Self.autosaveName) { center() }
        setFrameAutosaveName(Self.autosaveName)
    }

    static let autosaveName = "FloatPinnedWindow"

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Esc doesn't hide a pinned window.
    override func cancelOperation(_ sender: Any?) {}

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let ok = super.makeFirstResponder(responder)
        if let editor = firstResponder as? NSTextView, editor.isFieldEditor { FieldEditorDrops.adopt(editor) }
        return ok
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { ImagePreview.shared.hasItems }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { ImagePreview.shared.begin(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { ImagePreview.shared.end(panel) }
}

/// SwiftUI text fields edit through a private field editor that takes a dropped file (or the
/// screenshot thumbnail) and types its path. Files and images go on to the card's drop target
/// instead, so they become attachments wherever they land; dragged text still drops into the field.
/// The editor can't be replaced (SwiftUI casts it to its own class), so it gets a runtime subclass,
/// the way KVO does it, whose drag methods forward attachment drags and leave the rest alone.
enum FieldEditorDrops {
    private static let prefix = "FloatDrops_"
    private static let imageTypes: [NSPasteboard.PasteboardType] =
        [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")]

    static func adopt(_ editor: NSTextView) {
        guard let base = object_getClass(editor) else { return }
        let baseName = NSStringFromClass(base)
        // Already adopted, or KVO has its own subclass in place: leave it be.
        guard !baseName.hasPrefix(prefix), !baseName.hasPrefix("NSKVONotifying_") else { return }
        let name = prefix + baseName
        if let existing = NSClassFromString(name) {
            object_setClass(editor, existing)
            return
        }
        guard let sub = objc_allocateClassPair(base, name, 0) else { return }
        forward(#selector(NSTextView.draggingEntered(_:)), in: sub, base: base) { ($0 as NSDraggingDestination).draggingEntered?($1).rawValue ?? 0 }
        forward(#selector(NSTextView.draggingUpdated(_:)), in: sub, base: base) { ($0 as NSDraggingDestination).draggingUpdated?($1).rawValue ?? 0 }
        forward(#selector(NSTextView.prepareForDragOperation(_:)), in: sub, base: base) { ($0 as NSDraggingDestination).prepareForDragOperation?($1) ?? true }
        forward(#selector(NSTextView.performDragOperation(_:)), in: sub, base: base) { ($0 as NSDraggingDestination).performDragOperation?($1) ?? false }
        forwardVoid(#selector(NSTextView.draggingExited(_:)), in: sub, base: base) { ($0 as NSDraggingDestination).draggingExited?($1) }
        forwardVoid(#selector(NSTextView.concludeDragOperation(_:)), in: sub, base: base) { ($0 as NSDraggingDestination).concludeDragOperation?($1) }
        objc_registerClassPair(sub)
        object_setClass(editor, sub)
    }

    /// The card's drop target (SwiftUI's `onDrop` view), when this drag carries files or images.
    private static func card(for editor: NSView, _ info: NSDraggingInfo) -> NSView? {
        let pb = info.draggingPasteboard
        let isAttachment = pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pb.availableType(from: imageTypes) != nil
            || pb.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
        guard isAttachment, let root = editor.window?.contentView else { return nil }
        let any = NSPasteboard.PasteboardType("public.item")
        func find(_ v: NSView) -> NSView? {
            if !(v is NSTextView), v.registeredDraggedTypes.contains(any) { return v }
            return v.subviews.lazy.compactMap(find).first
        }
        return find(root)
    }

    private static func forward(_ sel: Selector, in sub: AnyClass, base: AnyClass,
                                _ call: @escaping (NSView, NSDraggingInfo) -> UInt) {
        typealias Original = @convention(c) (AnyObject, Selector, NSDraggingInfo) -> UInt
        guard let imp = class_getMethodImplementation(base, sel) else { return }
        let original = unsafeBitCast(imp, to: Original.self)
        let block: @convention(block) (NSTextView, NSDraggingInfo) -> UInt = { editor, info in
            guard let card = card(for: editor, info) else { return original(editor, sel, info) }
            return call(card, info)
        }
        add(sel, block, to: sub, base: base)
    }

    private static func forward(_ sel: Selector, in sub: AnyClass, base: AnyClass,
                                _ call: @escaping (NSView, NSDraggingInfo) -> Bool) {
        typealias Original = @convention(c) (AnyObject, Selector, NSDraggingInfo) -> Bool
        guard let imp = class_getMethodImplementation(base, sel) else { return }
        let original = unsafeBitCast(imp, to: Original.self)
        let block: @convention(block) (NSTextView, NSDraggingInfo) -> Bool = { editor, info in
            guard let card = card(for: editor, info) else { return original(editor, sel, info) }
            return call(card, info)
        }
        add(sel, block, to: sub, base: base)
    }

    private static func forwardVoid(_ sel: Selector, in sub: AnyClass, base: AnyClass,
                                    _ call: @escaping (NSView, NSDraggingInfo) -> Void) {
        typealias Original = @convention(c) (AnyObject, Selector, NSDraggingInfo?) -> Void
        guard let imp = class_getMethodImplementation(base, sel) else { return }
        let original = unsafeBitCast(imp, to: Original.self)
        let block: @convention(block) (NSTextView, NSDraggingInfo?) -> Void = { editor, info in
            guard let info, let card = card(for: editor, info) else { return original(editor, sel, info) }
            call(card, info)
        }
        add(sel, block, to: sub, base: base)
    }

    private static func add(_ sel: Selector, _ block: Any, to sub: AnyClass, base: AnyClass) {
        guard let types = class_getInstanceMethod(base, sel).flatMap(method_getTypeEncoding) else { return }
        class_addMethod(sub, sel, imp_implementationWithBlock(block), types)
    }
}

final class PanelController {
    let presentation = PanelPresentation()
    private var panel: QuickPanel!
    /// Separate presentation for the pinned window: it is always "presented" while it exists.
    private let pinnedPresentation = PanelPresentation()
    private var pinnedWindow: PinnedWindow?
    private var isPinned: Bool { Preferences.shared.pinned }
    private var hideWork: DispatchWorkItem?
    private var dismissWork: DispatchWorkItem?
    private let store: ChatStore
    var onShow: (() -> Void)?

    /// How long a click-away waits before a compact panel hides, so a quick trip elsewhere doesn't lose it.
    private static let clickAwayGrace: TimeInterval = 0.05

    /// Once there's a conversation, a draft, an attachment, voice in use, or an open list or prompt, the panel stays
    /// put like a normal window; until then it's a launcher that goes away when you click elsewhere.
    private var isExpanded: Bool {
        !store.messages.isEmpty || !store.draft.isEmpty || !store.attachments.isEmpty
            || store.showingHistory || store.activePrompt != nil
            || store.voice.phase != .idle || store.voice.isConversing
    }

    private var pasteMonitor: Any?
    /// The collapsed pill at the notch (unpinned mode only).
    private var notch: NotchWindow!
    private var hoverWork: DispatchWorkItem?
    private var collapseTimer: Timer?
    private var mouseWasInside = false
    private var outsideSince: Date?

    #if DEBUG
    var window: NSWindow { panel }
    #endif

    init(store: ChatStore) {
        self.store = store
        let root = QuickChatView()
            .environment(store)
            .environment(presentation)
        panel = QuickPanel(content: root)
        panel.onCancel = { [weak self] in self?.hide() }
        presentation.refit = { [weak self] in self?.refit() }
        // ⌘V with a copied file or image attaches it instead of pasting text.
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak store] event in
            guard let self, let store, event.window === self.panel || event.window === self.pinnedWindow else { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            // ⌘W puts a pinned window away (the hotkey or the Dock icon brings it back).
            if mods == .command, event.charactersIgnoringModifiers == "w", event.window === self.pinnedWindow {
                self.pinnedWindow?.orderOut(nil)
                return nil
            }
            if mods == .command, event.charactersIgnoringModifiers == "k" {
                store.toggleHistory()
                return nil
            }
            // Past-chats list: arrows and return drive the list while the search field keeps typing.
            if store.showingHistory {
                if mods == .command, event.charactersIgnoringModifiers == "n" { store.newChat(); return nil }
                if mods.isEmpty {
                    switch event.keyCode {
                    case 125: store.moveHistory(1); return nil      // ↓
                    case 126: store.moveHistory(-1); return nil     // ↑
                    case 36, 76: store.openSelectedHistory(); return nil
                    case 53: store.closeHistory(); return nil       // esc goes back to the chat
                    default: break
                    }
                }
            }
            // Slash menu keys win over the text field.
            if store.showSlash, event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                switch event.keyCode {
                case 125: store.moveSlash(1); return nil          // ↓
                case 126: store.moveSlash(-1); return nil         // ↑
                case 48: store.insertSlash(); return nil          // ⇥
                case 36, 76: store.runSelectedSlash(); return nil // ↩
                case 53: store.dismissSlash(); return nil         // esc
                default: break
                }
            }
            if mods.isEmpty, !store.showSlash, !store.showingHistory {
                // esc leaves edit mode instead of hiding the panel.
                if event.keyCode == 53, store.editingMessageId != nil { store.cancelEdit(); return nil }
                // ↑ in an empty composer brings back the last message (not while a card's own field has focus).
                if event.keyCode == 126, !(event.window?.firstResponder is NSSecureTextField),
                   store.activePrompt == nil, store.recallLastPrompt() { return nil }
            }
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v" else { return event }
            let pb = NSPasteboard.general
            let hasFiles = pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hasImage = pb.availableType(from: [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")]) != nil
            // A long block of text pasted into the composer becomes a chip, as in Claude and ChatGPT.
            if !hasFiles, !hasImage, store.composerFocused, store.activeQuestion == nil, Attachment.isLongPaste(text) {
                store.addAttachments([Attachment.pasted(pb.string(forType: .string) ?? text)])
                return nil
            }
            guard hasFiles || (hasImage && (text.isEmpty || text.hasPrefix("http"))) else { return event }
            let items = Attachment.fromPasteboard(pb)
            guard !items.isEmpty else { return event }
            store.addAttachments(items)
            return nil
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleClickAwayDismiss() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissWork?.cancel() }
        }
        Preferences.shared.onPinnedChange = { [weak self] in self?.applyPinned() }
        notch = NotchWindow(store: store)
        notch.host.onClick = { [weak self] in self?.toggle() }
        notch.host.onHover = { [weak self] inside in self?.pillHover(inside) }
        notch.host.menuProvider = { [weak self] in self?.makeMenu() ?? NSMenu() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePill() }
        }
        updatePill()
        applyPlacement()
        trackExpansion()
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                UserDefaults.standard.set(NSStringFromPoint(self.panel.frame.origin), forKey: "panelOrigin")
            }
        }
    }

    var isVisible: Bool {
        if isPinned { return (pinnedWindow?.isVisible ?? false) && NSApp.isActive }
        return panel.isVisible && presentation.isPresented
    }

    /// The hotkey hides a panel you can see; from another desktop it brings an expanded panel here instead.
    /// A pinned window is only ever brought to the front.
    func toggle() {
        if isPinned { showPinned(); return }
        isVisible && panel.isOnActiveSpace ? hide() : show()
    }

    // MARK: Notch pill

    /// The pill sits at the notch whenever Float isn't pinned (a pinned window has its Dock icon instead).
    private func updatePill() {
        if isPinned {
            notch.orderOut(nil)
        } else {
            notch.place()
            notch.orderFrontRegardless()
        }
    }

    private func pillHover(_ inside: Bool) {
        hoverWork?.cancel()
        guard inside, !isPinned, !isVisible else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, NotchState.shared.hovering, !self.isVisible else { return }
            self.show()
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// The pill's right-click menu: everything the old menu bar icon offered.
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let hk = Preferences.shared.hotKey
        menu.addItem(ClosureMenuItem("Open Float  \(hk.label)") { [weak self] in self?.show() })
        menu.addItem(ClosureMenuItem("New Chat", key: "n") { [weak self] in self?.store.newChat(); self?.show() })
        menu.addItem(ClosureMenuItem("Past Chats…", key: "k") { [weak self] in self?.show(); self?.store.openHistory() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Pinned Window", checked: isPinned) { Preferences.shared.pinned.toggle() })
        menu.addItem(ClosureMenuItem("Settings…", key: ",") { SettingsOpener.open() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Quit Float", key: "q") { NSApp.terminate(nil) })
        return menu
    }

    /// While the chat is open from the notch, close it once the mouse has been in and then left the
    /// card and the pill, as long as nothing is going on: no draft, voice, question, list or reply in flight.
    private func startCollapseWatch() {
        collapseTimer?.invalidate()
        mouseWasInside = isMouseOverChat()
        outsideSince = nil
        collapseTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkCollapse() }
        }
    }

    private func stopCollapseWatch() {
        collapseTimer?.invalidate()
        collapseTimer = nil
    }

    private func isMouseOverChat() -> Bool {
        let mouse = NSEvent.mouseLocation
        if notch.frame.insetBy(dx: -4, dy: -4).contains(mouse) { return true }
        let f = presentation.cardFrame
        guard f.width > 0 else { return panel.frame.contains(mouse) }
        let card = NSRect(x: panel.frame.minX + f.minX, y: panel.frame.maxY - f.maxY, width: f.width, height: f.height)
        return card.insetBy(dx: -12, dy: -12).contains(mouse)
    }

    private var isIdleForCollapse: Bool {
        store.draft.isEmpty && store.attachments.isEmpty && store.activePrompt == nil && !store.showingHistory
            && !store.isBusy && store.voice.phase == .idle && !store.voice.isConversing
            && store.editingMessageId == nil && NSEvent.pressedMouseButtons == 0
            && !store.showSlash
    }

    private func checkCollapse() {
        guard !isPinned, isVisible else { stopCollapseWatch(); return }
        if isMouseOverChat() {
            mouseWasInside = true
            outsideSince = nil
            return
        }
        guard mouseWasInside, isIdleForCollapse else { outsideSince = nil; return }
        if let since = outsideSince {
            if Date().timeIntervalSince(since) > 0.5 { hide() }
        } else {
            outsideSince = Date()
        }
    }

    // MARK: Pinned window

    /// Switch between the floating panel and the pinned window, carrying the chat across.
    private func applyPinned() {
        if isPinned {
            hideWork?.cancel(); dismissWork?.cancel()
            presentation.isPresented = false
            NotchState.shared.expanded = false
            stopCollapseWatch()
            panel.orderOut(nil)
            updatePill()
            showPinned()
        } else {
            pinnedWindow?.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
            updatePill()
            show()
        }
    }

    private func showPinned() {
        let window = pinnedWindow ?? makePinnedWindow()
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        pinnedPresentation.focusToken += 1
        onShow?()
    }

    private func makePinnedWindow() -> PinnedWindow {
        pinnedPresentation.isPresented = true
        let root = QuickChatView()
            .environment(store)
            .environment(pinnedPresentation)
            .environment(\.floatPinned, true)
        let window = PinnedWindow(content: root)
        pinnedWindow = window
        return window
    }

    /// Always above other apps (full-screen spaces too). Compact follows you across desktops;
    /// expanded stays on its desktop and is pulled to the current one when summoned.
    private func applyPlacement() {
        let expanded = isExpanded
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = expanded
            ? [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
            : [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    private func trackExpansion() {
        withObservationTracking {
            _ = isExpanded
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.applyPlacement()
                self?.trackExpansion()
            }
        }
    }

    /// Hides an unused compact panel after you click into another app. Screenshots, and our own dialogs
    /// and previews (the app stays active for those), don't count as clicking away.
    private func scheduleClickAwayDismiss() {
        dismissWork?.cancel()
        guard !isPinned, !isExpanded, isVisible else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !NSApp.isActive, !self.isExpanded, self.isVisible else { return }
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.screencaptureui" { return }
            self.hide()
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.clickAwayGrace, execute: work)
    }

    func show() {
        if isPinned { showPinned(); return }
        hideWork?.cancel()
        dismissWork?.cancel()
        applyPlacement()
        if !panel.isVisible { position() }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.makeKey()
        NSApp.activate()
        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
            presentation.isPresented = true
        }
        NotchState.shared.expanded = true
        presentation.focusToken += 1
        startCollapseWatch()
        onShow?()
    }

    func hide() {
        guard !isPinned else { return }
        stopCollapseWatch()
        NotchState.shared.expanded = false
        withAnimation(.spring(response: 0.28, dampingFraction: 0.95)) {
            presentation.isPresented = false
        }
        let work = DispatchWorkItem { [weak self] in
            self?.panel.orderOut(nil)
            NSApp.hide(nil)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    /// Resize the window to the card's saved size, keeping its top edge and horizontal centre in place,
    /// so dragging either side grows the card evenly like Spotlight.
    private func refit() {
        let size = QuickPanel.fittingSize()
        let old = panel.frame
        guard old.size != size else { return }
        panel.setFrame(NSRect(x: (old.midX - size.width / 2).rounded(), y: old.maxY - size.height,
                              width: size.width, height: size.height), display: true)
    }

    /// Hang the panel from the notch (or the top-centre pill), so it opens downward out of it.
    private func position() {
        if let g = NotchGeometry.current() {
            let size = panel.frame.size
            // The card sits 28 pt into the window; this puts its top edge just under the pill.
            let top = g.screenFrame.maxY - g.height + 22
            panel.setFrameOrigin(NSPoint(x: (g.screenFrame.midX - size.width / 2).rounded(), y: top - size.height))
            return
        }
        legacyPosition()
    }

    /// Reuse the spot the panel was last dragged to; otherwise centre it on the screen with the mouse.
    private func legacyPosition() {
        if let saved = UserDefaults.standard.string(forKey: "panelOrigin") {
            let origin = NSPointFromString(saved)
            let frame = NSRect(origin: origin, size: panel.frame.size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame.insetBy(dx: 200, dy: 200)) }) {
                panel.setFrameOrigin(origin)
                return
            }
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let x = vf.midX - size.width / 2
        let y = vf.maxY - size.height - vf.height * 0.08
        panel.setFrameOrigin(NSPoint(x: x, y: max(vf.minY, y)))
    }
}
