import Foundation
import os

/// Resolves the App Group this build was actually signed with.
///
/// Why this exists (2026-10-10 launch crash):
/// the signer derives the group from the *final* bundle id, and a sideloaded free-account build gets
/// a team-id suffix — the profile granted `group.io.github.collinsomniac.nabla.FRJQU6T5U5` while the
/// code asked for `group.io.github.collinsomniac.nabla`. `containerURL(forSecurityApplicationGroupIdentifier:)`
/// then returns **nil**, and the old force-unwrap (`... containerURL(...)!`) trapped in
/// `AIChatViewModel.minisAppGroupRoot` during `SoulStore.load()` in `MinisApp.init()`. EXC_BREAKPOINT,
/// seven frames, before the first frame was drawn.
///
/// So: read the granted groups from the embedded provisioning profile, use the first one, and if
/// there is none fall back to a directory inside this app's own container. Every caller keeps a
/// valid URL, and nothing shares state with another app.
enum AppGroupResolver {
    private static let log = Logger(subsystem: "io.github.collinsomniac.nabla", category: "AppGroup")

    /// The group id granted by the provisioning profile, if any.
    static let grantedGroupID: String? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<plist"), let end = text.range(of: "</plist>")
        else { return nil }
        let plistData = Data(text[start.lowerBound..<end.upperBound].utf8)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let ents = plist["Entitlements"] as? [String: Any],
              let groups = ents["com.apple.security.application-groups"] as? [String],
              let first = groups.first
        else { return nil }
        return first
    }()

    /// Container for the granted group, or a private fallback inside this app's own container.
    /// Never nil, so callers do not have to unwrap.
    static let container: URL = {
        let fm = FileManager.default
        if let id = grantedGroupID, let url = fm.containerURL(forSecurityApplicationGroupIdentifier: id) {
            log.info("app group container: \(id, privacy: .public)")
            return url
        }
        // No group granted (or not yet provisioned). Keep a stable, app-private location so paths
        // stay valid and nothing leaks into another app's container.
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent(grantedGroupID == nil ? "AppGroupFallback" : "AppGroupUnavailable", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        log.warning("no app group granted; using private container at \(dir.path, privacy: .public)")
        return dir
    }()

    /// True when the real shared container is in use (as opposed to the private fallback).
    static var hasRealGroup: Bool { grantedGroupID != nil }
}
