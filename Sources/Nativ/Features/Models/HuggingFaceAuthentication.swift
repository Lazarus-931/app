import Foundation

enum HuggingFaceAuthentication {
    static let environmentVariableName = "HF_TOKEN"

    static func authorize(_ request: inout URLRequest, token: String?) {
        guard let token = normalizedToken(token) else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    static func effectiveToken(customToken: String?, environmentToken: String?) -> String? {
        normalizedToken(customToken) ?? normalizedToken(environmentToken)
    }

    static func normalizedToken(_ token: String?) -> String? {
        guard let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
