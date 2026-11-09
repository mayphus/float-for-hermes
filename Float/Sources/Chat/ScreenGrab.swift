import AppKit
import CoreGraphics
import ScreenCaptureKit

/// One still of the display under the mouse, only when asked (the eye button or "look at my screen").
/// Float's own windows are left out. The JPEG lives in memory as an attachment; nothing goes to disk.
enum ScreenGrab {
    static let longEdge: CGFloat = 1600

    /// Typed or spoken requests that mean "use my screen".
    static func wantsScreen(_ text: String) -> Bool {
        let t = text.lowercased()
        let phrases = ["look at my screen", "see my screen", "what's on my screen", "whats on my screen",
                       "what is on my screen", "this screen", "on my screen", "check my screen", "my screen?",
                       "look at the screen", "see the screen", "what's on the screen", "what am i looking at"]
        return phrases.contains { t.contains($0) }
    }

    enum Failure: Error { case noPermission, noDisplay, encode }

    static func capture() async throws -> Attachment {
        guard CGPreflightScreenCaptureAccess() else {
            askForPermissionOnce()
            throw Failure.noPermission
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let screenID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let display = content.displays.first(where: { $0.displayID == screenID }) ?? content.displays.first else {
            throw Failure.noDisplay
        }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let w = CGFloat(display.width), h = CGFloat(display.height)
        let scale = min(1, longEdge / max(w, h)) * 2  // displays report points; capture at up to 2x, then cap
        let cap = min(1, longEdge / (max(w, h) * scale)) * scale
        config.width = Int(w * cap)
        config.height = Int(h * cap)
        config.showsCursor = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { throw Failure.encode }
        let thumb = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        return Attachment(url: nil, name: "Screen \(Attachment.stamp()).jpg", data: jpeg, isImage: true, thumbnail: thumb)
    }

    /// The first time, ask macOS (which adds Float to the list) and open the Screen Recording pane.
    private static func askForPermissionOnce() {
        let key = "screenPermissionAsked"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    static let permissionNote = "Float needs Screen Recording to see your screen. Turn it on in System Settings › Privacy & Security › Screen Recording, then try again."
}

extension Attachment {
    var isScreen: Bool { isImage && name.hasPrefix("Screen ") && url == nil }
}
