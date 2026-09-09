import Foundation

/// Non-secret, per-provider preferences that don't fit `AppSettings`
/// (owned by the integrator, additive-only) — currently just the base URL
/// for the generic "OpenAI-compatible" provider. Small enough to keep as
/// its own UserDefaults-backed blob rather than asking to extend a shared
/// contract for one field.
struct AIProviderPreferences: Codable, Equatable {
    /// Provider id -> base URL string (e.g. `"openai-compatible"` ->
    /// `"http://localhost:1234/v1"`).
    var customBaseURLs: [String: String] = [:]

    private static let defaultsKey = "reviewrr.ai.providerPreferences"

    static func load() -> AIProviderPreferences {
        guard
            let data = UserDefaults.standard.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode(AIProviderPreferences.self, from: data)
        else {
            return AIProviderPreferences()
        }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    static func baseURL(for providerID: String) -> URL? {
        load().customBaseURLs[providerID].flatMap { URL(string: $0) }
    }

    static func setBaseURL(_ urlString: String, for providerID: String) {
        var prefs = load()
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            prefs.customBaseURLs.removeValue(forKey: providerID)
        } else {
            prefs.customBaseURLs[providerID] = trimmed
        }
        prefs.save()
    }
}
