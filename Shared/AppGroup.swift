import Foundation

/// Resolves the app-group container shared by the app and the keyboard. Sideloading tools may
/// rename the group (AltStore/SideStore list the real ids in `ALTAppGroups`), so it is never hard-coded.
enum AppGroup {
    static let defaultIdentifier = "group.com.keibord.app"

    static let resolvedIdentifier: String? = {
        for id in candidates() {
            guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) else { continue }
            let dir = url.appendingPathComponent("Keibord", isDirectory: true)
            if (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil {
                return id
            }
        }
        return nil
    }()

    static var containerURL: URL? {
        resolvedIdentifier.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }

    static var isAvailable: Bool { containerURL != nil }

    static func candidates() -> [String] {
        var ids: [String] = []
        if let alt = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] {
            ids += alt.filter { $0.lowercased().contains("keibord") } + alt.filter { !$0.lowercased().contains("keibord") }
        }
        ids += provisioningProfileGroups()
        // "group.$(KEIBORD_BUNDLE_ID)" from project.yml: App Store/TestFlight builds carry no
        // embedded.mobileprovision, so with a custom bundle id this is the only way to find the group.
        if let built = Bundle.main.object(forInfoDictionaryKey: "KeibordAppGroup") as? String, !built.isEmpty, !built.contains("$(") {
            ids.append(built)
        }
        ids.append(defaultIdentifier)
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// Reads `com.apple.security.application-groups` from the embedded provisioning profile.
    static func provisioningProfileGroups() -> [String] {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), options: [], in: start.lowerBound..<data.endIndex) else {
            return []
        }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = (try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String] else {
            return []
        }
        return groups
    }

    static var diagnostics: String {
        let resolved = resolvedIdentifier ?? "none"
        return "App group: \(resolved)\nCandidates: \(candidates().joined(separator: ", "))"
    }
}
