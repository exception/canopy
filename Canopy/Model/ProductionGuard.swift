import AppKit
import LocalAuthentication

/// Touch ID / password confirmation for changes on production connections.
@MainActor
enum ProductionGuard {
    /// `reason` completes the system sentence "Canopy is trying to …".
    static func authorize(_ reason: String) async -> Bool {
        // Automation and tests can't press a finger on a sensor.
        if let stub = ProcessInfo.processInfo.environment["CANOPY_AUTH_STUB"] { return stub == "allow" }
        let ctx = LAContext()
        ctx.localizedCancelTitle = "Don't change anything"
        var err: NSError?
        // .deviceOwnerAuthentication = Touch ID, Apple Watch, or the login password as fallback.
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return fallbackConfirm(reason) }
        do { return try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) } catch { return false }
    }

    /// No biometrics and no password policy available (rare): an explicit confirmation instead.
    private static func fallbackConfirm(_ reason: String) -> Bool {
        let a = NSAlert()
        a.messageText = "Production change"
        a.informativeText = "Canopy is about to \(reason). Continue?"
        a.alertStyle = .critical
        a.addButton(withTitle: "Continue")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }
}
