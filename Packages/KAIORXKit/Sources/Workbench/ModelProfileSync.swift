import Domain
import Foundation
import Providers
import Storage

/// Registers the real providers' model profiles from the verified catalog (ADR 0012). Outside
/// tests this is the only place that makes Claude and Codex profiles usable; it runs at every
/// app start and on the user's re-check (ADR 0012 D7) and gives the same result when run twice.
///
/// Per provider, one catalog version is active:
/// - the installed version, when exactly that build passed the live acceptance;
/// - otherwise (not installed, not identified, unlisted, not live, another build, or not read
///   because the channel permits no automation) the newest catalog version whose matrix entry is
///   `liveVerified`. Its profiles stay usable on purpose: the scheduler looks for a profile
///   before it asks the gate, so the task then waits with the gate's precise reason ("version x
///   not live-verified") instead of "no matching model profile". Safety does not depend on it:
///   the gate and `AdapterPolicy` refuse every start of an unverified build.
///
/// The fallback may pick a version other than the installed one when the installation is not
/// read (distributed channel, a failed probe). A profile of that version may name a model that
/// never ran with the installed build; `AdapterPolicy.checkModel` refuses such a start at every
/// launch, so only a model/version/role triple the catalog lists ever runs.
///
/// Profiles of other catalog versions get `catalog:otherVersion <version>`; those whose matrix
/// entry is not `liveVerified` get `catalog:versionNotLiveVerified`.
public enum ModelProfileSync {
    /// The providers whose profiles come only from the catalog.
    public static let managed: Set<ProviderKind> = [.claude, .codex]

    public static func desired(
        entries: [VerifiedModelEntry] = VerifiedModelProfiles.entries, matrix: [CompatibilityEntry] = CompatibilityMatrix.entries,
        installed: [ProviderKind: BinaryIdentity]
    ) -> [ModelProfile] {
        var profiles: [ModelProfile] = []
        var seen = Set<ModelProfileID>()
        for provider in ProviderKind.allCases where managed.contains(provider) {
            let own = entries.enumerated().filter { $0.element.provider == provider }
            func live(_ version: String) -> Bool {
                matrix.contains { $0.provider == provider && $0.version == version && $0.status == .liveVerified }
            }
            let active: String?
            if let identity = installed[provider], CompatibilityMatrix.liveVerification(provider, identity: identity, in: matrix) == .verified {
                active = identity.version
            } else {
                active = own.filter { live($0.element.version) }
                    .max { ($0.element.verifiedOn, $0.offset) < ($1.element.verifiedOn, $1.offset) }?.element.version
            }
            for (_, entry) in own {
                let reason: String? = if !live(entry.version) {
                    "catalog:versionNotLiveVerified"
                } else if entry.version != active {
                    "catalog:otherVersion \(entry.version)"
                } else {
                    nil
                }
                for role in AttemptRole.allCases where entry.roles.contains(role) {
                    let id = VerifiedModelProfiles.profileID(entry, role: role)
                    guard seen.insert(id).inserted else { continue }
                    profiles.append(ModelProfile(
                        id: id, provider: provider, role: role, tier: entry.tier, model: entry.model, effort: entry.effort,
                        typicalTokens: entry.typicalTokens, verifiedAt: VerifiedModelProfiles.verifiedAt(entry), disabledReason: reason
                    ))
                }
            }
        }
        return profiles
    }

    @discardableResult
    public static func run(
        store: Store, installed: [ProviderKind: BinaryIdentity], entries: [VerifiedModelEntry] = VerifiedModelProfiles.entries,
        matrix: [CompatibilityEntry] = CompatibilityMatrix.entries
    ) async throws -> ModelProfileSyncReport {
        try await store.syncCatalogModelProfiles(desired(entries: entries, matrix: matrix, installed: installed), managed: managed)
    }
}
