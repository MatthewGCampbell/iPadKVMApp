import Foundation
import Security

struct HostProfile: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = ""
    var host = ""
    var port = 5900
    var username = "admin"
    var serverKind: ServerKind = .pikvm
    var security: TransportSecurity = .tls
    var jpegQuality = 8
    var pinnedCertificateSHA256: String?

    // Keyboard & mouse
    var commandShortcutsAsTaps = true
    var swapCommandAndOption = false
    var clipboardShortcut = true
    var optionStandsInForCommand = true
    var invertScroll = false

    // Clipboard
    var copyRemoteClipboard = true

    var displayName: String { name.isEmpty ? host : name }

    init() {}

    // Tolerates saved data from older versions that lack newer fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HostProfile()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? d.id
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? d.host
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? d.username
        serverKind = try c.decodeIfPresent(ServerKind.self, forKey: .serverKind) ?? d.serverKind
        security = try c.decodeIfPresent(TransportSecurity.self, forKey: .security) ?? d.security
        jpegQuality = try c.decodeIfPresent(Int.self, forKey: .jpegQuality) ?? d.jpegQuality
        pinnedCertificateSHA256 = try c.decodeIfPresent(String.self, forKey: .pinnedCertificateSHA256)
        commandShortcutsAsTaps = try c.decodeIfPresent(Bool.self, forKey: .commandShortcutsAsTaps) ?? d.commandShortcutsAsTaps
        swapCommandAndOption = try c.decodeIfPresent(Bool.self, forKey: .swapCommandAndOption) ?? d.swapCommandAndOption
        clipboardShortcut = try c.decodeIfPresent(Bool.self, forKey: .clipboardShortcut) ?? d.clipboardShortcut
        optionStandsInForCommand = try c.decodeIfPresent(Bool.self, forKey: .optionStandsInForCommand) ?? d.optionStandsInForCommand
        invertScroll = try c.decodeIfPresent(Bool.self, forKey: .invertScroll) ?? d.invertScroll
        copyRemoteClipboard = try c.decodeIfPresent(Bool.self, forKey: .copyRemoteClipboard) ?? d.copyRemoteClipboard
    }
}

/// Saved hosts in UserDefaults, passwords in the Keychain.
final class HostStore: ObservableObject {
    @Published private(set) var hosts: [HostProfile] = []

    private let defaultsKey = "hosts.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([HostProfile].self, from: data) {
            hosts = decoded
        }
    }

    func save(_ profile: HostProfile, password: String?) {
        if let index = hosts.firstIndex(where: { $0.id == profile.id }) {
            hosts[index] = profile
        } else {
            hosts.append(profile)
        }
        if let password { Keychain.setPassword(password, for: profile.id) }
        persist()
    }

    func delete(_ profile: HostProfile) {
        hosts.removeAll { $0.id == profile.id }
        Keychain.deletePassword(for: profile.id)
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        hosts.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func pinCertificate(_ sha256: String, for id: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == id }),
              hosts[index].pinnedCertificateSHA256 == nil else { return }
        hosts[index].pinnedCertificateSHA256 = sha256
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(hosts) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

enum Keychain {
    private static let service = "KVMRemote.host-password"

    static func password(for id: UUID) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func setPassword(_ password: String, for id: UUID) {
        deletePassword(for: id)
        guard !password.isEmpty else { return }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(password.utf8),
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func deletePassword(for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
