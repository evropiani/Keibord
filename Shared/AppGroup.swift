import Foundation

/// Resolves the app-group container shared by the app and the keyboard. Sideloading tools may
/// rename the group (AltStore/SideStore list the real ids in `ALTAppGroups`), so it is never hard-coded.
enum AppGroup {
    static let defaultIdentifier = "group.com.keibord.app"
    /// Info.plist key set by project.yml to `group.$(KEIBORD_BUNDLE_ID)` in both targets.
    static let infoPlistKey = "KeibordAppGroup"

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

    /// Candidate group ids in priority order (computed once: parsing the provisioning profile is not free).
    static func candidates() -> [String] { cachedCandidates }

    private static let cachedCandidates: [String] = orderedCandidates(
        infoPlistGroup: Bundle.main.object(forInfoDictionaryKey: infoPlistKey),
        altGroups: Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups"),
        profileGroups: provisioningProfileGroups()
    )

    /// Order: (1) the `KeibordAppGroup` Info.plist value (bundle-id dependent, also present in TestFlight
    /// builds that have no embedded.mobileprovision), (2) `ALTAppGroups` (ids containing "keibord" first),
    /// (3) the provisioning profile's groups, (4) the default id. Unexpanded build settings, empty
    /// strings and duplicates are dropped.
    static func orderedCandidates(infoPlistGroup: Any?, altGroups: Any?, profileGroups: [String]) -> [String] {
        func usable(_ value: Any?) -> String? {
            guard let string = value as? String else { return nil }
            let id = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !id.contains("$(") else { return nil }
            return id
        }
        var ids: [String] = []
        if let id = usable(infoPlistGroup) { ids.append(id) }
        if let alt = altGroups as? [Any] {
            let groups = alt.compactMap { usable($0) }
            ids += groups.filter { $0.lowercased().contains("keibord") } + groups.filter { !$0.lowercased().contains("keibord") }
        }
        ids += profileGroups.compactMap { usable($0) }
        ids.append(defaultIdentifier)
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// Reads `com.apple.security.application-groups` from the embedded provisioning profile.
    static func provisioningProfileGroups() -> [String] {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else {
            return []
        }
        return groups(fromProvisioningProfile: data)
    }

    /// Extracts the application groups from the XML plist embedded in a (CMS-signed) provisioning profile.
    static func groups(fromProvisioningProfile data: Data) -> [String] {
        guard let start = data.range(of: Data("<?xml".utf8)),
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
