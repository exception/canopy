import AppKit

/// With a hidden title bar and a SwiftUI toolbar, AppKit stops treating a double-click on the
/// window's top strip as "zoom". This puts it back, honoring System Settings
/// (Desktop & Dock › "Double-click a window's title bar to": Zoom / Fill / Minimize / Do Nothing).
@MainActor
enum TitlebarDoubleClick {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { e in
            guard e.clickCount == 2, let w = e.window, w.styleMask.contains(.titled), isEmptyTitlebar(e.locationInWindow, in: w) else { return e }
            perform(on: w)
            return nil
        }
    }

    /// True when the point is in the toolbar/title strip and not on something clickable.
    static func isEmptyTitlebar(_ p: NSPoint, in w: NSWindow) -> Bool {
        guard p.y >= w.contentLayoutRect.maxY, let frameView = w.contentView?.superview else { return false }
        // The SwiftUI content extends under the toolbar, so empty strip space hit-tests to the
        // split view's hosting views; only real controls and toolbar items should keep the click.
        var v = frameView.hitTest(frameView.convert(p, from: nil))
        while let view = v {
            if view is NSControl || view is NSTextView { return false }
            if NSStringFromClass(type(of: view)).contains("ToolbarItemHostingView") { return false }
            v = view.superview
        }
        return true
    }

    static func perform(on w: NSWindow) {
        let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
        switch action {
        case "Minimize": w.performMiniaturize(nil)
        case "None": break
        default: w.zoom(nil) // "Maximize" (Zoom) and "Fill" both mean filling the screen.
        }
    }

    /// Automation: what a double-click at window point (x, y from top-left) would do.
    static func describe(_ x: CGFloat, _ yFromTop: CGFloat, in w: NSWindow) -> String {
        let p = NSPoint(x: x, y: w.frame.height - yFromTop)
        guard let fv = w.contentView?.superview else { return "no frame" }
        var chain: [String] = []
        var v = fv.hitTest(fv.convert(p, from: nil))
        while let view = v, chain.count < 8 { chain.append(NSStringFromClass(type(of: view))); v = view.superview }
        return (isEmptyTitlebar(p, in: w) ? "zoom" : "pass") + " " + chain.joined(separator: " < ")
    }
}
