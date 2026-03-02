@preconcurrency import Cocoa

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: 30)

        let icon = NSImage(size: NSSize(width: 30, height: 22), flipped: false) { rect in
            let trackColor = NSColor(red: 0x3a / 255.0, green: 0x35 / 255.0, blue: 0x30 / 255.0, alpha: 1.0)
            trackColor.setFill()

            // Top bar: y=4, height=4, full width
            let topBar = NSRect(x: 0, y: 4, width: rect.width, height: 4)
            topBar.fill()

            // Bottom bar: y=13, height=4, full width
            let bottomBar = NSRect(x: 0, y: 13, width: rect.width, height: 4)
            bottomBar.fill()

            return true
        }
        icon.isTemplate = false

        if let button = statusItem.button {
            button.image = icon
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
