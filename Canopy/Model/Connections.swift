import Foundation
import Security

struct SavedConnection: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// Connection string without the password; the password lives in the Keychain.
    var uri: String
    var color: UInt32 = 0x3DD68C
    var readOnly = false
    var favorite = false
    var lastUsed: Date?
    /// Optional so connections saved before this flag existed still decode.
    var production: Bool?

    /// Production connections need Touch ID (or the Mac password) for destructive or wide changes.
    var isProduction: Bool {
        get { production ?? false }
        set { production = newValue }
    }

    var host: String {
        guard let c = URLComponents(string: uri.replacingOccurrences(of: "mongodb+srv://", with: "https://").replacingOccurrences(of: "mongodb://", with: "https://")) else { return uri }
        return [c.host, c.port.map { ":\($0)" }].compactMap { $0 }.joined()
    }

    var isSRV: Bool { uri.hasPrefix("mongodb+srv://") }
    var username: String? {
        URLComponents(string: uri.replacingOccurrences(of: "mongodb+srv://", with: "https://").replacingOccurrences(of: "mongodb://", with: "https://"))?.user?.removingPercentEncoding
    }
}

/// Splits a pasted connection string into a password-free URI + password.
enum ConnectionString {
    static func split(_ raw: String) -> (uri: String, password: String?) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeEnd = s.range(of: "://"), let at = s[schemeEnd.upperBound...].firstIndex(of: "@") else { return (s, nil) }
        let creds = s[schemeEnd.upperBound..<at]
        guard let colon = creds.firstIndex(of: ":") else { return (s, nil) }
        let user = creds[..<colon]
        let pass = String(creds[creds.index(after: colon)...]).removingPercentEncoding
        return (String(s[..<schemeEnd.upperBound]) + user + String(s[at...]), pass)
    }

    static func join(_ uri: String, password: String?) -> String {
        guard let password, !password.isEmpty, let schemeEnd = uri.range(of: "://"), let at = uri[schemeEnd.upperBound...].firstIndex(of: "@") else { return uri }
        let user = uri[schemeEnd.upperBound..<at]
        if user.contains(":") { return uri }
        let enc = password.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? password
        return String(uri[..<schemeEnd.upperBound]) + user + ":" + enc + String(uri[at...])
    }
}

enum Keychain {
    static let service = "dev.canopy.connections"

    static func set(_ password: String?, for id: UUID) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
        SecItemDelete(q as CFDictionary)
        guard let password, !password.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ id: UUID) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: id.uuidString, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

/// Everything Canopy keeps on disk, in ~/Library/Application Support/Canopy
/// (or $CANOPY_HOME for isolated runs).
enum Storage {
    static var dir: URL {
        let base: URL
        if let h = ProcessInfo.processInfo.environment["CANOPY_HOME"] { base = URL(fileURLWithPath: h) }
        else { base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Canopy") }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func load<T: Decodable>(_ name: String, as: T.Type) -> T? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(T.self, from: d)
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(value).write(to: dir.appendingPathComponent(name), options: .atomic)
    }
}

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var namespace: String
    var kind: String // find | aggregate
    var filter: String
    var sort: String
    var project: String
    var pipeline: String
    var at: Date
    var favorite = false
    var title: String?
}
