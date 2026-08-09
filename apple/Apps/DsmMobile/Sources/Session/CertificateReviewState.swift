import DsmCore
import DsmNetwork
import Foundation

struct MobileCertificatePrompt: Identifiable {
    let id = UUID()
    let error: DsmCertificateTrustError
    let previousFingerprint: String?

    var review: DsmCertificateReview {
        error.review
    }

    var isCertificateChange: Bool {
        if case .changed = error {
            return true
        }
        return false
    }

    var allowsPinning: Bool {
        guard review.canBePinned else { return false }
        if case .invalid = error {
            return false
        }
        return true
    }

    var formattedPreviousFingerprint: String? {
        guard let previousFingerprint else { return nil }
        return Self.formatFingerprint(previousFingerprint)
    }

    private static func formatFingerprint(_ fingerprint: String) -> String {
        stride(from: 0, to: fingerprint.count, by: 2).map { offset in
            let start = fingerprint.index(fingerprint.startIndex, offsetBy: offset)
            let end = fingerprint.index(
                start,
                offsetBy: min(2, fingerprint.distance(from: start, to: fingerprint.endIndex))
            )
            return String(fingerprint[start..<end])
        }.joined(separator: ":")
    }
}

enum MobileCertificateRetryContext {
    case connect(submission: MobileConnectionSubmission)
    case restore(profile: NasProfile, fallbackToPassword: Bool)
}

struct MobileConnectionSubmission {
    let profile: NasProfile
    let account: String
    let password: String
    let otpCode: String?
    let rememberPassword: Bool
    let autoLoginEnabled: Bool

    func updating(profile: NasProfile) -> MobileConnectionSubmission {
        MobileConnectionSubmission(
            profile: profile,
            account: account,
            password: password,
            otpCode: otpCode,
            rememberPassword: rememberPassword,
            autoLoginEnabled: autoLoginEnabled
        )
    }
}
