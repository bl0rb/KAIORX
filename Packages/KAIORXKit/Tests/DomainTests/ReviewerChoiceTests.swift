import Foundation
import Testing
@testable import Domain

/// The one reviewer rule (ADR 0011): the same choice the scheduler made inline before
/// (`Scheduler.swift`, reviewer consent and profile) and the consent `IntegrationService.startReview`
/// requires for a plan task.
@Suite struct ReviewerChoiceTests {
    let project = ProjectID()
    let job = JobID()
    let now: Int64 = 1_000

    func consent(
        _ provider: ProviderKind, roles: [AttemptRole] = [.author, .reviewer], job: JobID? = nil, expiresAt: Int64? = nil, revokedAt: Int64? = nil
    ) -> ConsentRecord {
        let draft = ConsentDraft(projectID: project, jobID: job, provider: provider, accountID: AccountID(), roles: roles, writeRoots: [""], expiresAt: expiresAt)
        return ConsentRecord(id: ConsentID(), draft: draft, scopeDigest: "", grantedAt: 0, revokedAt: revokedAt)
    }

    func profile(_ provider: ProviderKind, role: AttemptRole = .reviewer, tier: CapabilityTier, model: String, verified: Bool = true, disabled: String? = nil) -> ModelProfile {
        ModelProfile(provider: provider, role: role, tier: tier, model: model, verifiedAt: verified ? 1 : nil, disabledReason: disabled)
    }

    @Test func reviewerComesFromAnotherProviderThanTheAuthor() {
        let claude = consent(.claude)
        let codex = consent(.codex)
        #expect(ReviewerChoice.reviewer(consents: [claude, codex], author: .claude, job: job, now: now) == codex)
        #expect(ReviewerChoice.reviewer(consents: [claude, codex], author: .codex, job: job, now: now) == claude)
        #expect(ReviewerChoice.reviewer(consents: [claude], author: .claude, job: job, now: now) == nil)
    }

    @Test func withoutAuthorTheFirstReviewerConsentCounts() {
        let claude = consent(.claude)
        let codex = consent(.codex)
        #expect(ReviewerChoice.reviewer(consents: [codex, claude], author: nil, job: job, now: now) == codex)
    }

    @Test func reviewerNeedsTheReviewerRole() {
        let authorOnly = consent(.codex, roles: [.author])
        let reviewer = consent(.fake, roles: [.reviewer])
        #expect(ReviewerChoice.reviewer(consents: [authorOnly, reviewer], author: .claude, job: job, now: now) == reviewer)
        #expect(ReviewerChoice.reviewer(consents: [authorOnly], author: .claude, job: job, now: now) == nil)
    }

    @Test func revokedExpiredAndOtherJobConsentsDoNotCount() {
        let revoked = consent(.codex, revokedAt: 10)
        let expired = consent(.codex, expiresAt: now)
        let otherJob = consent(.codex, job: JobID())
        let thisJob = consent(.codex, job: job)
        let valid = consent(.codex, expiresAt: now + 1)
        #expect(ReviewerChoice.reviewer(consents: [revoked, expired, otherJob], author: .claude, job: job, now: now) == nil)
        #expect(ReviewerChoice.reviewer(consents: [revoked, expired, otherJob, thisJob], author: .claude, job: job, now: now) == thisJob)
        #expect(ReviewerChoice.reviewer(consents: [revoked, valid], author: .claude, job: job, now: now) == valid)
        // Without a job only project-wide consents count.
        #expect(ReviewerChoice.reviewer(consents: [thisJob], author: .claude, job: nil, now: now) == nil)
    }

    /// The rule the scheduler applied inline: filter valid consents of the project or job, then
    /// the first reviewer from another provider.
    @Test func matchesTheSchedulersInlineRule() {
        let pool = [
            consent(.claude), consent(.codex, roles: [.author]), consent(.codex, revokedAt: 1), consent(.fake, job: JobID()),
            consent(.codex, job: job), consent(.fake), consent(.codex, expiresAt: 5),
        ]
        for author in ProviderKind.allCases {
            let filtered = pool.filter { $0.isValid(at: now) && ($0.draft.jobID == nil || $0.draft.jobID == job) }
            let inline = filtered.first(where: { $0.draft.roles.contains(.reviewer) && $0.draft.provider != author })
            #expect(ReviewerChoice.reviewer(consents: pool, author: author, job: job, now: now) == inline, "\(author)")
        }
    }

    @Test func consentForAProviderIsExactlyThatProvider() {
        let claude = consent(.claude)
        let codexAuthor = consent(.codex, roles: [.author])
        let codexOtherJob = consent(.codex, job: JobID())
        let codex = consent(.codex, roles: [.reviewer], job: job)
        let pool = [claude, codexAuthor, codexOtherJob, codex]
        #expect(ReviewerChoice.consent(consents: pool, provider: .codex, job: job, now: now) == codex)
        #expect(ReviewerChoice.consent(consents: pool, provider: .claude, job: job, now: now) == claude)
        #expect(ReviewerChoice.consent(consents: pool, provider: .fake, job: job, now: now) == nil)
    }

    @Test func profileIsTheSmallestUsableReviewerProfile() {
        let intensive = profile(.codex, tier: .intensive, model: "a")
        let standard = profile(.codex, tier: .standard, model: "b")
        let fastUnverified = profile(.codex, tier: .fast, model: "c", verified: false)
        let fastDisabled = profile(.codex, tier: .fast, model: "d", disabled: "off")
        let fastAuthor = profile(.codex, role: .author, tier: .fast, model: "e")
        let otherProvider = profile(.claude, tier: .fast, model: "f")
        let all = [intensive, standard, fastUnverified, fastDisabled, fastAuthor, otherProvider]
        #expect(ReviewerChoice.profile(all, provider: .codex) == standard)
        #expect(ReviewerChoice.profile(all, provider: .codex) == ModelProfile.smallest(all, provider: .codex, role: .reviewer, atLeast: .fast))
        #expect(ReviewerChoice.profile(all, provider: .claude) == otherProvider)
        #expect(ReviewerChoice.profile([fastUnverified, fastAuthor], provider: .codex) == nil)
    }
}
