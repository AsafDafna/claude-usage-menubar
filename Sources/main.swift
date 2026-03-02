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
    let credentialManager: CredentialManager
    private var currentCredentials: OAuthCredentials?

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
        let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        var request = URLRequest(url: url)
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
        let url = URL(string: "https://platform.claude.com/v1/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": token,
            "scope": "user:profile user:inference user:sessions:claude_code user:mcp_servers"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let data, error == nil else {
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
                print("[meter] Failed to decode refresh response: \(error)")
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

func drawMenuBarIcon(fiveHour: Double, sevenDay: Double) -> NSImage {
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

        return true
    }
    image.isTemplate = false
    return image
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    var credentialManager: CredentialManager = CredentialManager()
    var apiClient: APIClient!
    var currentUsage: UsageResponse?

    func applicationDidFinishLaunching(_ notification: Notification) {
        apiClient = APIClient(credentialManager: credentialManager)

        statusItem = NSStatusBar.system.statusItem(withLength: 30)

        // Show gray bars initially
        updateIcon()

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        fetchUsage()
    }

    func updateIcon() {
        let fiveHour = currentUsage?.fiveHour?.utilization ?? 0
        let sevenDay = currentUsage?.sevenDay?.utilization ?? 0
        let icon = drawMenuBarIcon(fiveHour: fiveHour, sevenDay: sevenDay)
        statusItem.button?.image = icon
    }

    func fetchUsage() {
        apiClient.fetchUsage { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let usage):
                    self.currentUsage = usage
                    self.updateIcon()
                    print("[meter] Usage - 5h: \(usage.fiveHour?.utilization ?? -1)%, 7d: \(usage.sevenDay?.utilization ?? -1)%")
                case .failure(let error):
                    print("[meter] Fetch error: \(error)")
                    self.currentUsage = nil
                    self.updateIcon()
                }
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
