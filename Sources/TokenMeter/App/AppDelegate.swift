import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        StatusBarManager.shared.start()
        print("TokenMeter started")
    }

    func applicationWillTerminate(_ notification: Notification) {
        print("TokenMeter exiting")
    }
}
