import Providers

/// What `kaiorx-acceptance preflight` says about an installed build. The product gate and
/// `AdapterPolicy` use the same check (`CompatibilityMatrix.liveVerification`); the end-to-end
/// script (`scripts/e2e-durchlauf.sh`) reads the line `Build <sha16>…: live abgenommen`.
public enum Preflight {
    public static func buildLine(_ verdict: LiveVerification, version: String, sha256: String) -> String {
        "Build \(sha256.prefix(16))…: " + text(verdict, version: version)
    }

    public static func text(_ verdict: LiveVerification, version: String) -> String {
        switch verdict {
        case .verified: "live abgenommen"
        case .versionNotListed: "NICHT live abgenommen (Version \(version) steht nicht in der Matrix)"
        case .versionNotLiveVerified: "NICHT live abgenommen (Version \(version) ist in der Matrix nicht live abgenommen)"
        case .buildNotVerified: "NICHT live abgenommen (anderer Build von \(version) als in der Abnahme)"
        }
    }
}
