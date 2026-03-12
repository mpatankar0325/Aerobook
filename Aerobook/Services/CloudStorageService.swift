import Foundation
import SwiftUI
import AuthenticationServices
import Combine
// MARK: - Cloud Provider Enum

enum CloudProvider: String, CaseIterable, Identifiable {
    case iCloud      = "iCloud"
    case oneDrive    = "OneDrive"
    case googleDrive = "Google Drive"
    case dropbox     = "Dropbox"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .iCloud:      return "icloud.fill"
        case .oneDrive:    return "cloud.fill"
        case .googleDrive: return "externaldrive.fill.badge.wifi"
        case .dropbox:     return "square.stack.3d.up.fill"
        }
    }
    var brandColor: Color {
        switch self {
        case .iCloud:      return Color(red: 0.0,  green: 0.48, blue: 1.0)
        case .oneDrive:    return Color(red: 0.01, green: 0.49, blue: 0.95)
        case .googleDrive: return Color(red: 0.26, green: 0.74, blue: 0.35)
        case .dropbox:     return Color(red: 0.00, green: 0.42, blue: 0.87)
        }
    }
    var tagline: String {
        switch self {
        case .iCloud:      return "Apple — built into iOS"
        case .oneDrive:    return "Microsoft 365 / Personal"
        case .googleDrive: return "Google Workspace / Personal"
        case .dropbox:     return "Personal / Business"
        }
    }

    // iCloud uses the native UIDocumentPickerViewController — no OAuth needed.
    var requiresOAuth: Bool {
        switch self {
        case .iCloud: return false
        default:      return true
        }
    }

    // MARK: OAuth endpoints (OAuth providers only)
    var authorizationURL: String {
        switch self {
        case .iCloud:      return ""
        case .oneDrive:    return "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
        case .googleDrive: return "https://accounts.google.com/o/oauth2/v2/auth"
        case .dropbox:     return "https://www.dropbox.com/oauth2/authorize"
        }
    }
    var tokenURL: String {
        switch self {
        case .iCloud:      return ""
        case .oneDrive:    return "https://login.microsoftonline.com/common/oauth2/v2.0/token"
        case .googleDrive: return "https://oauth2.googleapis.com/token"
        case .dropbox:     return "https://api.dropboxapi.com/oauth2/token"
        }
    }
    var scopes: String {
        switch self {
        case .iCloud:      return ""
        case .oneDrive:    return "files.read offline_access"
        case .googleDrive: return "https://www.googleapis.com/auth/drive.readonly"
        case .dropbox:     return "files.content.read files.metadata.read"
        }
    }
    var clientID: String {
        switch self {
        case .iCloud:      return ""
        case .oneDrive:    return CloudStorageConfig.oneDriveClientID
        case .googleDrive: return CloudStorageConfig.googleClientID
        case .dropbox:     return CloudStorageConfig.dropboxClientID
        }
    }
    var redirectURI: String {
        guard requiresOAuth else { return "" }
        return "aerobook://oauth/\(rawValue.lowercased().replacingOccurrences(of: " ", with: ""))"
    }
}

// MARK: - App Config
// ┌─ Register your app and fill in real client IDs before shipping ────────────────┐
// │  OneDrive   → https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps      │
// │  Google     → https://console.cloud.google.com/apis/credentials                │
// │  Dropbox    → https://www.dropbox.com/developers/apps                          │
// └────────────────────────────────────────────────────────────────────────────────┘
struct CloudStorageConfig {
    static let oneDriveClientID   = "YOUR_ONEDRIVE_CLIENT_ID"
    static let googleClientID     = "YOUR_GOOGLE_CLIENT_ID"
    static let dropboxClientID    = "YOUR_DROPBOX_CLIENT_ID"
}

// MARK: - OAuth Token

struct OAuthToken: Codable {
    var accessToken:  String
    var refreshToken: String
    var expiresAt:    Date
    var provider:     String
    var isExpired: Bool { Date() > expiresAt.addingTimeInterval(-60) }
}

// MARK: - Cloud File Model

struct CloudFile: Identifiable, Hashable {
    let id:          String
    let name:        String
    let size:        Int64
    let modifiedAt:  Date
    let provider:    CloudProvider
    let downloadURL: String?
    let mimeType:    String

    var fileExtension: String { (name as NSString).pathExtension.lowercased() }
    var isLogbookFile: Bool { ["csv","xlsx","xls","zip","txt"].contains(fileExtension) }

    var fileIcon: String {
        switch fileExtension {
        case "csv":             return "tablecells.fill"
        case "xlsx","xls":      return "tablecells.badge.ellipsis"
        case "zip":             return "doc.zipper"
        default:                return "doc.fill"
        }
    }
    var sizeLabel: String {
        let kb = Double(size) / 1_024
        return kb < 1_024 ? String(format: "%.0f KB", kb) : String(format: "%.1f MB", kb / 1_024)
    }
    var modifiedLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(modifiedAt)     { return "Today" }
        if cal.isDateInYesterday(modifiedAt) { return "Yesterday" }
        let df = DateFormatter(); df.dateStyle = .medium
        return df.string(from: modifiedAt)
    }
}

// MARK: - Errors

enum CloudError: LocalizedError {
    case notAuthenticated, invalidURL, authCancelled, missingCode, tokenExchangeFailed
    case downloadFailed(String), configurationRequired(CloudProvider)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:     return "Not connected. Please connect first."
        case .invalidURL:           return "Invalid OAuth URL."
        case .authCancelled:        return "Authentication was cancelled."
        case .missingCode:          return "Authorization code not received from provider."
        case .tokenExchangeFailed:  return "Failed to obtain access token."
        case .downloadFailed(let m): return "Download failed: \(m)"
        case .configurationRequired(let p):
            return "\(p.rawValue) client ID not configured. See CloudStorageConfig in CloudStorageService.swift."
        }
    }
}

// MARK: - Cloud Storage Service

@MainActor
final class CloudStorageService: NSObject, ObservableObject,
                                  ASWebAuthenticationPresentationContextProviding {

    static let shared = CloudStorageService()

    @Published var connectedProviders: Set<CloudProvider> = []
    @Published var isAuthenticating = false
    @Published var authError: String?
    @Published var files: [CloudFile] = []
    @Published var isLoadingFiles = false
    @Published var isDownloading  = false
    @Published var downloadProgress: Double = 0

    private var tokens: [CloudProvider: OAuthToken] = [:]
    private let keychainService = "com.aerobook.cloudtokens"
    private var authSession: ASWebAuthenticationSession?

    private override init() {
        super.init()
        loadTokensFromKeychain()
    }

    // MARK: - Provider configured?

    func isConfigured(_ provider: CloudProvider) -> Bool {
        switch provider {
        case .iCloud:      return true   // native — no client ID needed
        case .oneDrive:    return CloudStorageConfig.oneDriveClientID   != "YOUR_ONEDRIVE_CLIENT_ID"
        case .googleDrive: return CloudStorageConfig.googleClientID     != "YOUR_GOOGLE_CLIENT_ID"
        case .dropbox:     return CloudStorageConfig.dropboxClientID    != "YOUR_DROPBOX_CLIENT_ID"
        }
    }

    // MARK: - Connect / Disconnect

    func connect(_ provider: CloudProvider) async {
        guard provider.requiresOAuth else {
            // iCloud is always "connected" via the native document picker
            connectedProviders.insert(provider)
            return
        }
        guard isConfigured(provider) else {
            authError = CloudError.configurationRequired(provider).localizedDescription
            return
        }
        isAuthenticating = true
        authError = nil
        do {
            let token = try await performOAuth(provider: provider)
            tokens[provider] = token
            saveTokenToKeychain(token, provider: provider)
            connectedProviders.insert(provider)
        } catch {
            authError = error.localizedDescription
        }
        isAuthenticating = false
    }

    func disconnect(_ provider: CloudProvider) {
        tokens.removeValue(forKey: provider)
        deleteTokenFromKeychain(provider)
        connectedProviders.remove(provider)
        files = files.filter { $0.provider != provider }
    }

    // MARK: - List Files

    func listFiles(provider: CloudProvider) async {
        guard provider.requiresOAuth else { return }   // iCloud uses UIDocumentPickerViewController
        guard var token = tokens[provider] else { authError = "Not authenticated."; return }
        isLoadingFiles = true
        authError = nil
        if token.isExpired {
            guard let refreshed = try? await refreshToken(token, provider: provider)
            else { isLoadingFiles = false; authError = "Session expired. Reconnect."; return }
            token = refreshed; tokens[provider] = refreshed
        }
        do {
            let fetched = try await fetchFiles(provider: provider, token: token)
            // Replace this provider's files, keep others
            files = files.filter { $0.provider != provider } + fetched
        } catch {
            authError = error.localizedDescription
        }
        isLoadingFiles = false
    }

    // MARK: - Download

    func download(_ file: CloudFile) async throws -> URL {
        guard var token = tokens[file.provider] else { throw CloudError.notAuthenticated }
        if token.isExpired {
            token = try await refreshToken(token, provider: file.provider)
            tokens[file.provider] = token
        }
        isDownloading = true; downloadProgress = 0
        defer { isDownloading = false; downloadProgress = 0 }

        let data = try await downloadData(file: file, token: token)
        downloadProgress = 1.0
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("aerobook_cloud_\(file.name)")
        try data.write(to: dest, options: .atomic)
        return dest
    }

    // MARK: - OAuth

    private func performOAuth(provider: CloudProvider) async throws -> OAuthToken {
        var comps = URLComponents(string: provider.authorizationURL)!
        comps.queryItems = [
            URLQueryItem(name: "client_id",     value: provider.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri",  value: provider.redirectURI),
            URLQueryItem(name: "scope",         value: provider.scopes),
            URLQueryItem(name: "state",         value: UUID().uuidString),
            URLQueryItem(name: "response_mode", value: "query"),
        ]
        guard let authURL = comps.url else { throw CloudError.invalidURL }

        return try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: "aerobook") { cb, err in
                if let err { cont.resume(throwing: err); return }
                guard let cb else { cont.resume(throwing: CloudError.authCancelled); return }
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        let t = try await self.exchangeCode(callbackURL: cb, provider: provider)
                        cont.resume(returning: t)
                    } catch { cont.resume(throwing: error) }
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.authSession = session
            session.start()
        }
    }

    private func exchangeCode(callbackURL: URL, provider: CloudProvider) async throws -> OAuthToken {
        guard let comps = URLComponents(url: callbackURL, resolvingAgainstBaseURL: true),
              let code  = comps.queryItems?.first(where: { $0.name == "code" })?.value
        else { throw CloudError.missingCode }

        var params: [String: String] = [
            "client_id": provider.clientID, "code": code,
            "grant_type": "authorization_code", "redirect_uri": provider.redirectURI,
        ]
        if provider == .dropbox { params["token_access_type"] = "offline" }
        return try await postTokenRequest(params: params, provider: provider)
    }

    private func refreshToken(_ token: OAuthToken, provider: CloudProvider) async throws -> OAuthToken {
        var params: [String: String] = [
            "client_id": provider.clientID, "refresh_token": token.refreshToken,
            "grant_type": "refresh_token",
        ]
        if provider == .dropbox { params["token_access_type"] = "offline" }
        return try await postTokenRequest(params: params, provider: provider)
    }

    private func postTokenRequest(params: [String: String], provider: CloudProvider) async throws -> OAuthToken {
        let body = params.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)"
        }.joined(separator: "&")
        var req = URLRequest(url: URL(string: provider.tokenURL)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String
        else { throw CloudError.tokenExchangeFailed }
        let refresh   = json["refresh_token"]  as? String ?? ""
        let expiresIn = json["expires_in"]     as? Double ?? 3600
        return OAuthToken(accessToken: access, refreshToken: refresh,
                          expiresAt: Date().addingTimeInterval(expiresIn), provider: provider.rawValue)
    }

    // MARK: - Provider file APIs

    private func fetchFiles(provider: CloudProvider, token: OAuthToken) async throws -> [CloudFile] {
        switch provider {
        case .iCloud:      return []   // handled natively — should never be called
        case .oneDrive:    return try await fetchOneDrive(token: token)
        case .googleDrive: return try await fetchGoogleDrive(token: token)
        case .dropbox:     return try await fetchDropbox(token: token)
        }
    }

    private func fetchOneDrive(token: OAuthToken) async throws -> [CloudFile] {
        var all: [CloudFile] = []
        for q in [".csv", ".xlsx", ".xls"] {
            let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
            var req = URLRequest(url: URL(string:
                "https://graph.microsoft.com/v1.0/me/drive/search(q='\(encoded)')?$top=50&$select=id,name,size,lastModifiedDateTime,@microsoft.graph.downloadUrl")!)
            req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["value"] as? [[String: Any]] else { continue }
            for item in items {
                guard let name = item["name"] as? String, let id = item["id"] as? String else { continue }
                let size   = item["size"] as? Int64 ?? 0
                let dlURL  = item["@microsoft.graph.downloadUrl"] as? String
                let modStr = item["lastModifiedDateTime"] as? String ?? ""
                let mod    = ISO8601DateFormatter().date(from: modStr) ?? Date()
                all.append(CloudFile(id: id, name: name, size: size, modifiedAt: mod,
                                     provider: .oneDrive, downloadURL: dlURL,
                                     mimeType: "application/octet-stream"))
            }
        }
        return all.filter { $0.isLogbookFile }.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private func fetchGoogleDrive(token: OAuthToken) async throws -> [CloudFile] {
        let q = "(name contains '.csv' or name contains '.xlsx' or name contains '.xls') and trashed=false"
        let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        var req = URLRequest(url: URL(string:
            "https://www.googleapis.com/drive/v3/files?q=\(encoded)&fields=files(id,name,size,modifiedTime,mimeType)&pageSize=50")!)
        req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["files"] as? [[String: Any]] else { return [] }
        return items.compactMap { item -> CloudFile? in
            guard let name = item["name"] as? String, let id = item["id"] as? String else { return nil }
            let size = Int64(item["size"] as? String ?? "0") ?? 0
            let mod  = ISO8601DateFormatter().date(from: item["modifiedTime"] as? String ?? "") ?? Date()
            return CloudFile(id: id, name: name, size: size, modifiedAt: mod,
                             provider: .googleDrive, downloadURL: nil,
                             mimeType: item["mimeType"] as? String ?? "")
        }.filter { $0.isLogbookFile }.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private func fetchDropbox(token: OAuthToken) async throws -> [CloudFile] {
        var all: [CloudFile] = []
        for ext in ["csv", "xlsx", "xls"] {
            var req = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/files/search_v2")!)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json",            forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject:
                ["query": ".\(ext)", "options": ["max_results": 50]])
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let matches = json["matches"] as? [[String: Any]] else { continue }
            for m in matches {
                guard let meta = (m["metadata"] as? [String: Any])?["metadata"] as? [String: Any],
                      let name = meta["name"] as? String,
                      let id   = meta["id"]   as? String else { continue }
                let size = meta["size"] as? Int64 ?? 0
                let mod  = ISO8601DateFormatter().date(from: meta["server_modified"] as? String ?? "") ?? Date()
                all.append(CloudFile(id: id, name: name, size: size, modifiedAt: mod,
                                     provider: .dropbox, downloadURL: nil,
                                     mimeType: "application/octet-stream"))
            }
        }
        return all.filter { $0.isLogbookFile }.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    // MARK: - Download data

    private func downloadData(file: CloudFile, token: OAuthToken) async throws -> Data {
        switch file.provider {
        case .iCloud:
            // iCloud files are picked via UIDocumentPickerViewController and arrive as local URLs
            throw CloudError.downloadFailed("iCloud files are opened directly via the document picker.")
        case .oneDrive:
            if let dlURL = file.downloadURL, let url = URL(string: dlURL) {
                let (data, _) = try await URLSession.shared.data(from: url); return data
            }
            var req = URLRequest(url: URL(string:
                "https://graph.microsoft.com/v1.0/me/drive/items/\(file.id)/content")!)
            req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await URLSession.shared.data(for: req); return data

        case .googleDrive:
            var req = URLRequest(url: URL(string:
                "https://www.googleapis.com/drive/v3/files/\(file.id)?alt=media")!)
            req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await URLSession.shared.data(for: req); return data

        case .dropbox:
            var req = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/download")!)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
            let argData  = try JSONSerialization.data(withJSONObject: ["path": file.id])
            req.setValue(String(data: argData, encoding: .utf8), forHTTPHeaderField: "Dropbox-API-Arg")
            let (data, _) = try await URLSession.shared.data(for: req); return data
        }
    }

    // MARK: - Keychain

    private func keychainKey(_ p: CloudProvider) -> String {
        "\(keychainService).\(p.rawValue.lowercased().replacingOccurrences(of: " ", with: "_"))"
    }
    private func saveTokenToKeychain(_ token: OAuthToken, provider: CloudProvider) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        let k = keychainKey(provider)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                 kSecAttrAccount as String: k,
                                 kSecAttrService as String: keychainService,
                                 kSecValueData as String: data,
                                 kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        SecItemDelete(q as CFDictionary); SecItemAdd(q as CFDictionary, nil)
    }
    private func loadTokensFromKeychain() {
        for provider in CloudProvider.allCases {
            let k = keychainKey(provider)
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrAccount as String: k,
                                     kSecAttrService as String: keychainService,
                                     kSecReturnData as String: true]
            var result: AnyObject?
            if SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
               let data  = result as? Data,
               let token = try? JSONDecoder().decode(OAuthToken.self, from: data) {
                tokens[provider] = token
                connectedProviders.insert(provider)
            }
        }
    }
    private func deleteTokenFromKeychain(_ provider: CloudProvider) {
        let k = keychainKey(provider)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrAccount as String: k,
                                  kSecAttrService as String: keychainService]
        SecItemDelete(q as CFDictionary)
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        DispatchQueue.main.sync {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first(where: { $0.isKeyWindow }) ?? ASPresentationAnchor()
        }
    }
}
