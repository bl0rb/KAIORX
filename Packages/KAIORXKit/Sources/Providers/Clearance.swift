import CryptoKit
import Domain
import Foundation

/// Who a build of KAIORX is for (ADR 0009). The app reads it from its Info.plist
/// (`KAIORXDistributionChannel`, set per build configuration); anything unknown or missing is
/// `distributed`, so a build that does not say otherwise never runs a provider on its own.
public enum DistributionChannel: String, Sendable, Codable, CaseIterable {
    /// The owner's own build from source (Debug configuration): automation as far as the
    /// compatibility matrix, the confinement probe and the subscription check allow.
    case personal
    /// Every build that may leave the owner's Mac (Release, `scripts/release.sh`): no real
    /// provider runs automatically without a provider clearance.
    case distributed

    public static let infoKey = "KAIORXDistributionChannel"

    /// Fails closed: only the exact value `personal` makes a personal build.
    public static func from(info: [String: Any]?) -> DistributionChannel {
        (info?[infoKey] as? String).flatMap(DistributionChannel.init(rawValue:)) ?? .distributed
    }

    /// The channel of the running app bundle.
    public static func current(bundle: Bundle = .main) -> DistributionChannel {
        from(info: bundle.infoDictionary)
    }
}

/// A provider's written permission for automatic runs in a channel (ADR 0009). Like a
/// `liveVerified` matrix entry, only the account owner adds one, together with the redacted
/// document it rests on; a test checks every entry against that document.
public struct ProviderClearance: Sendable, Equatable, Codable {
    public var provider: ProviderKind
    public var channel: DistributionChannel
    /// What the provider allowed, in the owner's words (roles, run mode, login path).
    public var scope: String
    /// The provider's statement in the repository (relative path below `docs/provider-clearance/`).
    public var documentPath: String
    public var documentSHA256: String
    /// Last day the clearance counts (`YYYY-MM-DD`, UTC); a release cadence shorter than this
    /// is the only way to withdraw it, because KAIORX has no network code (ADR 0007).
    public var expiresOn: String

    public init(provider: ProviderKind, channel: DistributionChannel, scope: String, documentPath: String, documentSHA256: String, expiresOn: String) {
        self.provider = provider
        self.channel = channel
        self.scope = scope
        self.documentPath = documentPath
        self.documentSHA256 = documentSHA256
        self.expiresOn = expiresOn
    }

    /// Today there is no provider clearance: distributed builds run no provider automatically.
    /// Only the account owner adds entries (never an agent), each with its document.
    public static let entries: [ProviderClearance] = []

    /// End of `expiresOn` in milliseconds since 1970; nil for a malformed date (never valid).
    public var expiresAt: Int64? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        // The round trip rejects dates the formatter would otherwise roll over (`2026-02-30`).
        guard let day = formatter.date(from: expiresOn), formatter.string(from: day) == expiresOn else { return nil }
        return Int64(day.timeIntervalSince1970 * 1000) + 86_400_000
    }

    public func permits(_ provider: ProviderKind, in channel: DistributionChannel, at now: Int64) -> Bool {
        guard self.provider == provider, self.channel == channel, let end = expiresAt else { return false }
        return now < end
    }
}

/// Checks a clearance against its document, like `EvidenceCheck` for the matrix.
public enum ClearanceCheck {
    public static let documentFolder = "docs/provider-clearance/"

    public static func problems(_ entry: ProviderClearance, repositoryRoot: String) -> [String] {
        var problems: [String] = []
        if entry.provider == .fake { problems.append("Testanbieter braucht keine Freigabe") }
        if entry.channel != .distributed { problems.append("Freigabe nur für den vertriebenen Kanal") }
        if entry.scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems.append("Umfang fehlt") }
        if entry.expiresAt == nil { problems.append("Ablaufdatum unlesbar: \(entry.expiresOn)") }
        let path = entry.documentPath
        guard path.hasPrefix(documentFolder), !path.split(separator: "/").contains("..") else {
            return problems + ["Dokument liegt nicht unter \(documentFolder)"]
        }
        guard let data = FileManager.default.contents(atPath: repositoryRoot + "/" + path) else { return problems + ["Dokument fehlt: \(path)"] }
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if sha != entry.documentSHA256 { problems.append("Dokument verändert") }
        return problems
    }
}
