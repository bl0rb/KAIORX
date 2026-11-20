import Domain
import Foundation
import Testing
@testable import Providers

@Suite struct CodexLimitMappingTests {
    @Test func limitsAndWindowsAreRead() throws {
        #expect(CodexRunHandle.limitKind(.string("usageLimitExceeded")) == .usageLimit)
        #expect(CodexRunHandle.limitKind(.string("rateLimitExceeded")) == .rateLimit)
        #expect(CodexRunHandle.limitKind(.string("serverOverloaded")) == nil)
        let http = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"httpConnectionFailed": {"httpStatusCode": 429}}"#.utf8))
        #expect(CodexRunHandle.limitKind(http) == .rateLimit)
        let snapshot = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
            {"limitId": "codex", "primary": {"usedPercent": 82, "resetsAt": 1800000000, "windowDurationMins": 300}, "secondary": null}
            """#.utf8))
        #expect(CodexRunHandle.quotaSignals(snapshot) == [
            QuotaSignal(windowKey: "codex:primary:300m", unit: .percent, used: 82, limit: 100, resetAt: 1_800_000_000_000),
        ])
    }
}
