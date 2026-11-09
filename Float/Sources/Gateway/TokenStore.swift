import Foundation

/// Persists the gateway token set as a single 0600 file under Application Support.
/// Same get/set/delete surface the app previously used for credentials; the account
/// key is ignored because Float keeps one active gateway URL.
enum TokenStore {
    private static var directoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Float", isDirectory: true)
    }

    private static var fileURL: URL {
        directoryURL.appendingPathComponent("token", isDirectory: false)
    }

    private static func ensureDirectory() throws {
        let fm = FileManager.default
        let dir = directoryURL
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } else {
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
    }

    static func set(_ data: Data, for account: String) {
        _ = account
        var tmp: URL?
        do {
            try ensureDirectory()
            let dest = fileURL
            let candidate = directoryURL.appendingPathComponent("token.tmp.\(UUID().uuidString)")
            tmp = candidate
            try data.write(to: candidate, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: candidate.path)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: candidate, to: dest)
            tmp = nil
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
        } catch {
            if let tmp { try? FileManager.default.removeItem(at: tmp) }
        }
    }

    static func get(_ account: String) -> Data? {
        _ = account
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func delete(_ account: String) {
        _ = account
        try? FileManager.default.removeItem(at: fileURL)
    }
}
