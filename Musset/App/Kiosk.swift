import AppKit
import ObjectiveC

/// Kiosk mode: Musset alone on the screen. No Dock, no menu bar, no ⌘Tab, no hiding the app, no logging out
/// by accident; the window, without its frame or buttons, covers the whole screen, notch and menu bar strip included. ⌃⌘K (still answered with the menu bar hidden) gives it all back.
/// ⌥⌘Esc stays open on purpose: if Musset ever hangs, the Mac must not be locked with it.
@MainActor
enum Kiosk {
    static let options: NSApplication.PresentationOptions = [
        .hideDock, .hideMenuBar,           // the menu bar can only hide with the Dock
        .disableProcessSwitching,          // ⌘Tab, ⌘⇥ (needs the Dock hidden)
        .disableHideApplication,           // ⌘H
        .disableSessionTermination,        // log out, restart, shut down from the keyboard
        .disableAppleMenu,
    ]

    /// The window as it was, given back on the way out.
    private struct Saved {
        var frame: NSRect
        var style: NSWindow.StyleMask
        var shadow: Bool
        var movable: Bool
        var options: NSApplication.PresentationOptions
    }

    private static var saved: Saved?
    private static var waiting: NSObjectProtocol?

    static var isOn: Bool { saved != nil }

    /// No title bar, so no window buttons, no rounded corners, no edge, no shadow.
    static let style: NSWindow.StyleMask = [.borderless, .resizable, .fullSizeContentView]

    /// A window without a title bar never takes the keyboard, and SwiftUI makes its own window. So its class answers
    /// `canBecomeKey` / `canBecomeMain` yes for the kiosk window alone, and as before for every other window.
    /// Only the two answers change, never the window's class: AppKit's observers of the window stay sound.
    nonisolated(unsafe) private static weak var kioskWindow: NSWindow?
    nonisolated(unsafe) private static var patched: Set<ObjectIdentifier> = []

    private static func letTakeKeyboard(_ window: NSWindow) {
        guard var cls = object_getClass(window) else { return }
        while NSStringFromClass(cls).hasPrefix("NSKVONotifying_"), let up = class_getSuperclass(cls) { cls = up }
        guard patched.insert(ObjectIdentifier(cls)).inserted else { return }
        for sel in [#selector(getter: NSWindow.canBecomeKey), #selector(getter: NSWindow.canBecomeMain)] {
            guard let m = class_getInstanceMethod(cls, sel) else { continue }
            typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
            let before = unsafeBitCast(method_getImplementation(m), to: Getter.self)
            let answer: @convention(block) (AnyObject) -> Bool = { me in me === kioskWindow || before(me, sel) }
            class_replaceMethod(cls, sel, imp_implementationWithBlock(answer), method_getTypeEncoding(m))
        }
    }

    static func enter(_ window: NSWindow?) {
        guard !isOn, let window, let screen = window.screen ?? NSScreen.main else { return }
        // A window in its own full-screen space keeps its own options: come out of it first.
        if window.styleMask.contains(.fullScreen) {
            waiting = NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated {
                    if let w = waiting { NotificationCenter.default.removeObserver(w); waiting = nil }
                    enter(window)
                }
            }
            window.toggleFullScreen(nil)
            return
        }
        saved = Saved(frame: window.frame, style: window.styleMask, shadow: window.hasShadow, movable: window.isMovable,
                      options: NSApp.presentationOptions)
        NSApp.presentationOptions = options
        let responder = window.firstResponder
        letTakeKeyboard(window)
        kioskWindow = window
        window.styleMask = style
        window.hasShadow = false
        window.isMovable = false
        // The whole screen, the strip of the menu bar and the notch's sides included: a window without a title bar
        // is not kept below the menu bar.
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        if let responder, responder !== window.firstResponder { window.makeFirstResponder(responder) }
    }

    static func leave(_ window: NSWindow?) {
        guard let s = saved else { return }
        saved = nil
        kioskWindow = nil
        NSApp.presentationOptions = s.options
        guard let window else { return }
        let responder = window.firstResponder
        window.styleMask = s.style
        window.hasShadow = s.shadow
        window.isMovable = s.movable
        window.setFrame(s.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        if let responder, responder !== window.firstResponder { window.makeFirstResponder(responder) }
    }
}
