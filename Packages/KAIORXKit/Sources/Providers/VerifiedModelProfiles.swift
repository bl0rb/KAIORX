import CryptoKit
import Domain
import Foundation

/// A model the owner's live acceptance (package A) exercised for a provider version, and the
/// roles it covered (ADR 0012). The app derives its real model profiles only from these entries;
/// an evidence test proves every entry against its committed report.
public struct VerifiedModelEntry: Sendable, Equatable {
    public var provider: ProviderKind
    /// Binds the entry to the matrix entry (provider, version) and through it to its builds.
    public var version: String
    /// The model string exactly as the acceptance passed it to the CLI.
    public var model: String
    /// The roles whose acceptance step passed (`StepID.exercising`).
    public var roles: [AttemptRole]
    /// A product setting, not evidence: which tasks the model takes (ADR 0012).
    public var tier: CapabilityTier
    /// nil: as accepted (the acceptance sets no effort).
    public var effort: String?
    /// nil until a report records usage; the scheduler then reserves its default, marked uncertain.
    public var typicalTokens: Int?
    /// The report's date (UTC day, `YYYY-MM-DD`).
    public var verifiedOn: String
    public var evidence: LiveEvidence

    public init(
        provider: ProviderKind, version: String, model: String, roles: [AttemptRole], tier: CapabilityTier, effort: String?,
        typicalTokens: Int?, verifiedOn: String, evidence: LiveEvidence
    ) {
        self.provider = provider
        self.version = version
        self.model = model
        self.roles = roles
        self.tier = tier
        self.effort = effort
        self.typicalTokens = typicalTokens
        self.verifiedOn = verifiedOn
        self.evidence = evidence
    }
}

/// The catalog of verified model profiles of the real providers (ADR 0012).
///
/// An entry is added or changed only when `EvidenceCheck.profileProblems` proves it against a
/// committed owner report, normally by applying the kit's `matrix.patch`. Never by hand. The tier
/// is the only field the owner may choose (it is not evidence). The entries of run
/// `20261120-1429-a265` are a one-time backfill from that committed report (ADR 0012).
public enum VerifiedModelProfiles {
    public static let entries: [VerifiedModelEntry] = [
        VerifiedModelEntry(
            provider: .claude, version: "2.1.329", model: "sonnet", roles: [.author, .reviewer],
            tier: .standard, // product setting (ADR 0012); the owner may change it before committing
            effort: nil, typicalTokens: nil, verifiedOn: "2026-11-20",
            evidence: LiveEvidence(reportPath: "docs/live-acceptance/20261120-1429-a265/report.json", reportSHA256: "0c7cac88969f6b5cdffe1381811f839c4afad47940ec21973b1ea8d7f946e4f0", mode: "claudeSubscription")
        ),
        VerifiedModelEntry(
            provider: .codex, version: "0.170.0", model: "gpt-6.2-sol", roles: [.author, .reviewer],
            tier: .standard, // product setting (ADR 0012); the owner may change it before committing
            effort: nil, typicalTokens: nil, verifiedOn: "2026-11-20",
            evidence: LiveEvidence(reportPath: "docs/live-acceptance/20261120-1429-a265/report.json", reportSHA256: "0c7cac88969f6b5cdffe1381811f839c4afad47940ec21973b1ea8d7f946e4f0", mode: "codexCliManaged")
        ),
        // kaiorx-acceptance: new entries above this line
    ]

    /// The line `ProfileProposal` inserts new entries above.
    public static let marker = "// kaiorx-acceptance: new entries above this line"

    /// A stable profile ID for one role of an entry: a name-based UUID (version 5 layout) over
    /// provider, version, model, role and tier. A new CLI version gets new rows, so attempts of
    /// the old version keep pointing at their own profile.
    public static func profileID(_ entry: VerifiedModelEntry, role: AttemptRole) -> ModelProfileID {
        let name = ["kaiorx.verifiedProfile", entry.provider.rawValue, entry.version, entry.model, role.rawValue, entry.tier.rawValue]
            .joined(separator: "|")
        var bytes = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return ModelProfileID(uuid)
    }

    /// `verifiedOn` as epoch milliseconds at 00:00 UTC; nil for anything but `YYYY-MM-DD`.
    public static func verifiedAt(_ entry: VerifiedModelEntry) -> Int64? {
        let parts = entry.verifiedOn.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(year: year, month: month, day: day)
        guard components.isValidDate(in: calendar), let date = calendar.date(from: components) else { return nil }
        return Int64(date.timeIntervalSince1970) * 1000
    }
}
