@preconcurrency import Cocoa
import Security

// MARK: - Credential Models

struct OAuthCredentials {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Int64  // milliseconds since epoch

    var isExpired: Bool {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        return nowMs >= expiresAt
    }
}

struct ClaudeAiOAuth: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Int64
}

struct CredentialFile: Codable {
    let claudeAiOauth: ClaudeAiOAuth
}

// MARK: - Credential Manager

class CredentialManager: @unchecked Sendable {
    func readCredentials() -> OAuthCredentials? {
        // Try file first, then Keychain
        if let creds = readFromFile() {
            return creds
        }
        return readFromKeychain()
    }

    private func readFromFile() -> OAuthCredentials? {
        let path = NSString("~/.claude/.credentials.json").expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path) else {
            return nil
        }
        do {
            let decoder = JSONDecoder()
            let file = try decoder.decode(CredentialFile.self, from: data)
            return OAuthCredentials(
                accessToken: file.claudeAiOauth.accessToken,
                refreshToken: file.claudeAiOauth.refreshToken,
                expiresAt: file.claudeAiOauth.expiresAt
            )
        } catch {
            print("[meter] Failed to decode credentials file: \(error)")
            return nil
        }
    }

    private func readFromKeychain() -> OAuthCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        // The Keychain stores a JSON string as the password data
        do {
            let decoder = JSONDecoder()
            let file = try decoder.decode(CredentialFile.self, from: data)
            return OAuthCredentials(
                accessToken: file.claudeAiOauth.accessToken,
                refreshToken: file.claudeAiOauth.refreshToken,
                expiresAt: file.claudeAiOauth.expiresAt
            )
        } catch {
            print("[meter] Failed to decode Keychain credentials: \(error)")
            return nil
        }
    }

    func persistCredentials(_ creds: OAuthCredentials) {
        let path = NSString("~/.claude/.credentials.json").expandingTildeInPath
        let oauthData = ClaudeAiOAuth(
            accessToken: creds.accessToken,
            refreshToken: creds.refreshToken,
            expiresAt: creds.expiresAt
        )
        let file = CredentialFile(claudeAiOauth: oauthData)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(file)
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            print("[meter] Failed to persist credentials: \(error)")
        }
    }
}

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
