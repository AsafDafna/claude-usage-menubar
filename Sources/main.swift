@preconcurrency import Cocoa
import Security
import os

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
            os_log(.error, "[meter] Failed to decode credentials file: %{public}@", error.localizedDescription)
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
            os_log(.error, "[meter] Failed to decode Keychain credentials: %{public}@", error.localizedDescription)
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
            let dirPath = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            os_log(.error, "[meter] Failed to persist credentials: %{public}@", error.localizedDescription)
        }
    }
}

// MARK: - Usage Models

struct UsageBucket: Codable {
    let utilization: Double
    let resetsAt: String

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

struct UsageResponse: Codable {
    let fiveHour: UsageBucket?
    let sevenDay: UsageBucket?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

// MARK: - Token Refresh Response

private struct TokenRefreshResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

// MARK: - API Client

enum APIError: Error {
    case noCredentials
    case refreshFailed
    case httpError(Int)
    case decodingError(Error)
    case networkError(Error)
}

class APIClient: @unchecked Sendable {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!

    let credentialManager: CredentialManager
    private let lock = DispatchQueue(label: "com.claude.usage-meter.api-client")
    private var _currentCredentials: OAuthCredentials?
    private var currentCredentials: OAuthCredentials? {
        get { lock.sync { _currentCredentials } }
        set { lock.sync { _currentCredentials = newValue } }
    }

    init(credentialManager: CredentialManager) {
        self.credentialManager = credentialManager
    }

    func fetchUsage(completion: @escaping @Sendable (Result<UsageResponse, Error>) -> Void) {
        guard let creds = credentialManager.readCredentials() else {
            completion(.failure(APIError.noCredentials))
            return
        }
        currentCredentials = creds

        if creds.isExpired {
            refreshToken(creds.refreshToken) { [weak self] newToken in
                guard let self, let newToken else {
                    completion(.failure(APIError.refreshFailed))
                    return
                }
                self.performUsageRequest(token: newToken, retryOnAuth: true, completion: completion)
            }
        } else {
            performUsageRequest(token: creds.accessToken, retryOnAuth: true, completion: completion)
        }
    }

    private func performUsageRequest(
        token: String,
        retryOnAuth: Bool,
        completion: @escaping @Sendable (Result<UsageResponse, Error>) -> Void
    ) {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error {
                completion(.failure(APIError.networkError(error)))
                return
            }

            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? 0

            // On 401/403, try refreshing once
            if (statusCode == 401 || statusCode == 403) && retryOnAuth {
                guard let self, let creds = self.currentCredentials else {
                    completion(.failure(APIError.refreshFailed))
                    return
                }
                self.refreshToken(creds.refreshToken) { [weak self] newToken in
                    guard let self, let newToken else {
                        completion(.failure(APIError.refreshFailed))
                        return
                    }
                    self.performUsageRequest(token: newToken, retryOnAuth: false, completion: completion)
                }
                return
            }

            guard statusCode == 200, let data else {
                completion(.failure(APIError.httpError(statusCode)))
                return
            }

            do {
                let usage = try JSONDecoder().decode(UsageResponse.self, from: data)
                completion(.success(usage))
            } catch {
                completion(.failure(APIError.decodingError(error)))
            }
        }
        task.resume()
    }

    private func refreshToken(_ token: String, completion: @escaping @Sendable (String?) -> Void) {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": token,
            "scope": "user:profile user:inference user:sessions:claude_code user:mcp_servers"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let data, error == nil else {
                os_log(.error, "[meter] Token refresh network error: %{public}@", error?.localizedDescription ?? "unknown")
                completion(nil)
                return
            }

            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? 0
            guard statusCode == 200 else {
                os_log(.error, "[meter] Token refresh failed with status %d", statusCode)
                completion(nil)
                return
            }

            do {
                let refreshResponse = try JSONDecoder().decode(TokenRefreshResponse.self, from: data)
                let newExpiresAt = Int64(Date().timeIntervalSince1970 * 1000) + Int64(refreshResponse.expiresIn) * 1000
                let newCreds = OAuthCredentials(
                    accessToken: refreshResponse.accessToken,
                    refreshToken: refreshResponse.refreshToken,
                    expiresAt: newExpiresAt
                )
                self?.currentCredentials = newCreds
                self?.credentialManager.persistCredentials(newCreds)
                completion(refreshResponse.accessToken)
            } catch {
                os_log(.error, "[meter] Failed to decode refresh response: %{public}@", error.localizedDescription)
                completion(nil)
            }
        }
        task.resume()
    }
}

// MARK: - Icon Rendering

func colorForPercent(_ pct: Double) -> NSColor {
    if pct <= 50 {
        return NSColor(red: 217.0 / 255.0, green: 119.0 / 255.0, blue: 60.0 / 255.0, alpha: 1.0)
    } else if pct <= 80 {
        return NSColor(red: 232.0 / 255.0, green: 168.0 / 255.0, blue: 56.0 / 255.0, alpha: 1.0)
    } else {
        return NSColor(red: 231.0 / 255.0, green: 76.0 / 255.0, blue: 60.0 / 255.0, alpha: 1.0)
    }
}

func drawMenuBarIcon(fiveHour: Double, sevenDay: Double, error: Bool = false) -> NSImage {
    let image = NSImage(size: NSSize(width: 30, height: 22), flipped: false) { _ in
        let trackColor = NSColor(red: 0x3a / 255.0, green: 0x35 / 255.0, blue: 0x30 / 255.0, alpha: 1.0)
        let trackX: CGFloat = 3
        let trackWidth: CGFloat = 24
        let barHeight: CGFloat = 4
        let cornerRadius: CGFloat = 2

        // Top bar (5h usage) at y=13
        let topTrack = NSBezierPath(roundedRect: NSRect(x: trackX, y: 13, width: trackWidth, height: barHeight), xRadius: cornerRadius, yRadius: cornerRadius)
        trackColor.setFill()
        topTrack.fill()

        let topFillWidth = trackWidth * CGFloat(min(max(fiveHour, 0), 100) / 100.0)
        if topFillWidth > 0 {
            let topFill = NSBezierPath(roundedRect: NSRect(x: trackX, y: 13, width: topFillWidth, height: barHeight), xRadius: cornerRadius, yRadius: cornerRadius)
            colorForPercent(fiveHour).setFill()
            topFill.fill()
        }

        // Bottom bar (7d usage) at y=5
        let bottomTrack = NSBezierPath(roundedRect: NSRect(x: trackX, y: 5, width: trackWidth, height: barHeight), xRadius: cornerRadius, yRadius: cornerRadius)
        trackColor.setFill()
        bottomTrack.fill()

        let bottomFillWidth = trackWidth * CGFloat(min(max(sevenDay, 0), 100) / 100.0)
        if bottomFillWidth > 0 {
            let bottomFill = NSBezierPath(roundedRect: NSRect(x: trackX, y: 5, width: bottomFillWidth, height: barHeight), xRadius: cornerRadius, yRadius: cornerRadius)
            colorForPercent(sevenDay).setFill()
            bottomFill.fill()
        }

        // Draw error indicator when there's no data and fetch failed
        if error {
            let errorFont = NSFont.boldSystemFont(ofSize: 11)
            let errorAttrs: [NSAttributedString.Key: Any] = [
                .font: errorFont,
                .foregroundColor: NSColor(red: 231.0 / 255.0, green: 76.0 / 255.0, blue: 60.0 / 255.0, alpha: 1.0)
            ]
            let errorStr = NSAttributedString(string: "!", attributes: errorAttrs)
            errorStr.draw(at: NSPoint(x: trackX + trackWidth - 3, y: 5))
        }

        return true
    }
    image.isTemplate = false
    return image
}

// MARK: - Reset Time Formatting

func formatResetTime(_ isoString: String) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let resetDate = formatter.date(from: isoString) ?? {
        // Try without fractional seconds as fallback
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: isoString)
    }() else {
        return ""
    }

    let now = Date()
    let delta = resetDate.timeIntervalSince(now)
    guard delta > 0 else { return "Resets soon" }

    let totalMinutes = Int(delta) / 60
    let days = totalMinutes / (60 * 24)
    let hours = (totalMinutes % (60 * 24)) / 60
    let minutes = totalMinutes % 60

    if days > 0 {
        return "Resets in \(days)d \(hours)h"
    } else if hours > 0 {
        return "Resets in \(hours)h \(minutes)m"
    } else {
        return "Resets in \(minutes)m"
    }
}

// MARK: - Usage Menu Item View

class UsageMenuItemView: NSView {
    let title: String
    var percentage: Double = 0
    var resetTime: String = ""

    init(title: String) {
        self.title = title
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 52))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let bgColor = NSColor(red: 0x2a / 255.0, green: 0x25 / 255.0, blue: 0x20 / 255.0, alpha: 1.0)
        bgColor.setFill()
        dirtyRect.fill()

        let padding: CGFloat = 12
        let contentWidth = bounds.width - padding * 2

        // Title (left) and percentage (right) - top row
        let titleFont = NSFont.boldSystemFont(ofSize: 13)
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: NSColor.white
        ]
        let titleStr = NSAttributedString(string: title, attributes: titleAttrs)
        titleStr.draw(at: NSPoint(x: padding, y: bounds.height - 18))

        let pctStr = NSAttributedString(string: "\(Int(percentage))%", attributes: titleAttrs)
        let pctSize = pctStr.size()
        pctStr.draw(at: NSPoint(x: bounds.width - padding - pctSize.width, y: bounds.height - 18))

        // Progress bar - middle row
        let barY: CGFloat = bounds.height - 30
        let barHeight: CGFloat = 6
        let cornerRadius: CGFloat = 3

        let trackColor = NSColor(red: 0x3a / 255.0, green: 0x35 / 255.0, blue: 0x30 / 255.0, alpha: 1.0)
        let trackRect = NSRect(x: padding, y: barY, width: contentWidth, height: barHeight)
        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: cornerRadius, yRadius: cornerRadius)
        trackColor.setFill()
        trackPath.fill()

        let fillWidth = contentWidth * CGFloat(min(max(percentage, 0), 100) / 100.0)
        if fillWidth > 0 {
            let fillRect = NSRect(x: padding, y: barY, width: fillWidth, height: barHeight)
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: cornerRadius, yRadius: cornerRadius)
            colorForPercent(percentage).setFill()
            fillPath.fill()
        }

        // Reset time text - bottom row
        if !resetTime.isEmpty {
            let resetFont = NSFont.systemFont(ofSize: 10)
            let resetAttrs: [NSAttributedString.Key: Any] = [
                .font: resetFont,
                .foregroundColor: NSColor.gray
            ]
            let resetStr = NSAttributedString(string: resetTime, attributes: resetAttrs)
            resetStr.draw(at: NSPoint(x: padding, y: 4))
        }
    }
}

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    var credentialManager: CredentialManager = CredentialManager()
    var apiClient: APIClient!
    var currentUsage: UsageResponse?
    private var pollingTimer: Timer?
    private var retryTimer: Timer?
    private var hasError: Bool = false

    private var fiveHourView: UsageMenuItemView!
    private var sevenDayView: UsageMenuItemView!

    // I5: Cache claude path to avoid blocking main thread repeatedly
    private var cachedClaudePath: String?
    private var claudePathResolved = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // M4: Set activation policy programmatically
        NSApp.setActivationPolicy(.accessory)

        apiClient = APIClient(credentialManager: credentialManager)

        statusItem = NSStatusBar.system.statusItem(withLength: 30)

        // Show gray bars initially
        updateIcon()

        // Build the menu
        fiveHourView = UsageMenuItemView(title: "Session (5h)")
        sevenDayView = UsageMenuItemView(title: "Weekly (7d)")

        let menu = NSMenu()
        menu.appearance = NSAppearance(named: .darkAqua)

        let fiveHourItem = NSMenuItem()
        fiveHourItem.view = fiveHourView
        menu.addItem(fiveHourItem)

        let sevenDayItem = NSMenuItem()
        sevenDayItem.view = sevenDayView
        menu.addItem(sevenDayItem)

        menu.addItem(NSMenuItem.separator())

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshClicked), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let loginItem = NSMenuItem(title: "Log in...", action: #selector(loginClicked), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu

        fetchUsage()

        // M3: Poll every 5 minutes (Timer on main run loop already dispatches on main)
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.fetchUsage()
            }
        }
    }

    func updateIcon() {
        let fiveHour = currentUsage?.fiveHour?.utilization ?? 0
        let sevenDay = currentUsage?.sevenDay?.utilization ?? 0
        let showError = hasError && currentUsage == nil
        let icon = drawMenuBarIcon(fiveHour: fiveHour, sevenDay: sevenDay, error: showError)
        statusItem.button?.image = icon
    }

    func updateMenu() {
        let fiveHourPct = currentUsage?.fiveHour?.utilization ?? 0
        let sevenDayPct = currentUsage?.sevenDay?.utilization ?? 0

        fiveHourView.percentage = fiveHourPct
        if let resetAt = currentUsage?.fiveHour?.resetsAt {
            fiveHourView.resetTime = formatResetTime(resetAt)
        } else {
            fiveHourView.resetTime = ""
        }
        fiveHourView.needsDisplay = true

        sevenDayView.percentage = sevenDayPct
        if let resetAt = currentUsage?.sevenDay?.resetsAt {
            sevenDayView.resetTime = formatResetTime(resetAt)
        } else {
            sevenDayView.resetTime = ""
        }
        sevenDayView.needsDisplay = true
    }

    func fetchUsage() {
        // Cancel any pending retry timer
        retryTimer?.invalidate()
        retryTimer = nil

        apiClient.fetchUsage { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let usage):
                    self.hasError = false
                    self.currentUsage = usage
                    self.updateIcon()
                    self.updateMenu()
                    os_log(.info, "[meter] Usage - 5h: %.1f%%, 7d: %.1f%%", usage.fiveHour?.utilization ?? -1, usage.sevenDay?.utilization ?? -1)
                case .failure(let error):
                    self.hasError = true
                    os_log(.error, "[meter] Fetch error: %{public}@", String(describing: error))
                    // Keep last known data; only reset if we never had data
                    if self.currentUsage == nil {
                        self.updateIcon()
                        self.updateMenu()
                    }
                    // I4: Retry after 30 seconds when we have no data
                    if self.currentUsage == nil {
                        self.retryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
                            MainActor.assumeIsolated {
                                self?.fetchUsage()
                            }
                        }
                    }
                }
            }
        }
    }

    @objc func refreshClicked() {
        fetchUsage()
    }

    @objc func loginClicked() {
        loginAndFetch()
    }

    // I5: Cache the claude path so `which` only runs once
    private func findClaudePath() -> String? {
        if claudePathResolved { return cachedClaudePath }
        claudePathResolved = true

        let knownPaths = ["/usr/local/bin/claude", "/opt/homebrew/bin/claude"]
        for path in knownPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                cachedClaudePath = path
                return path
            }
        }
        // Fall back to `which claude`
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["claude"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !result.isEmpty && FileManager.default.isExecutableFile(atPath: result) {
                cachedClaudePath = result
                return result
            }
        } catch {
            os_log(.error, "[meter] Failed to run which: %{public}@", error.localizedDescription)
        }
        return nil
    }

    // C1: Escape AppleScript path to prevent command injection
    private func loginAndFetch() {
        guard let claudePath = findClaudePath() else {
            os_log(.error, "[meter] Claude CLI not found")
            return
        }
        let escaped = claudePath.replacingOccurrences(of: "\\", with: "\\\\")
                                .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\" to do script \"\(escaped) /login\""
        var errorInfo: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            os_log(.error, "[meter] AppleScript error: %{public}@", errorInfo.description)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
