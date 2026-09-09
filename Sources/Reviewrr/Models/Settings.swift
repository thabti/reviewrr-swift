import SwiftUI

enum Appearance: String, CaseIterable, Codable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum InterfaceTextSize: String, CaseIterable, Codable, Identifiable {
    case compact, standard, large, extraLarge

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact: return "Compact"
        case .standard: return "Standard"
        case .large: return "Large"
        case .extraLarge: return "Extra Large"
        }
    }

    /// Multiplies every opted-in font size. Kept modest at both ends: past
    /// roughly ±25% the inbox row's fixed columns stop lining up.
    var scale: CGFloat {
        switch self {
        case .compact: return 0.9
        case .standard: return 1.0
        case .large: return 1.12
        case .extraLarge: return 1.24
        }
    }
}

enum DiffLayout: String, CaseIterable, Codable, Identifiable {
    case split, unified

    var id: String { rawValue }
    var label: String { self == .split ? "Split" : "Unified" }
    var symbol: String { self == .split ? "rectangle.split.2x1" : "list.bullet.rectangle" }
}

/// App-wide preferences. Persisted as JSON in UserDefaults.
///
/// Decoding is field-by-field with defaults (`decodeIfPresent`) on purpose:
/// adding a property must never make an existing stored blob undecodable,
/// which would silently reset every other preference the user has set.
struct AppSettings: Codable, Equatable {
    // Appearance and workspace
    var appearance: Appearance = .system
    var diffLayout: DiffLayout = .split
    var wordWrap: Bool = false
    /// Raw values of `FileCategory` hidden by default in the file tree.
    var hiddenFileCategories: Set<String> = ["lockfile", "generated"]
    var startOnDashboard: Bool = true
    /// Set when the Keychain refuses this build, so the next launch does not
    /// walk into the same panel. Not a secret — a note that asking again on
    /// our own initiative is unwelcome. Cleared by "Try the Keychain again".
    var keychainAccessDeclined: Bool = false
    var textSize: InterfaceTextSize = .standard
    /// Inbox sections the reviewer has collapsed, by group key. Persisted
    /// because a collapsed project is a statement about attention — losing
    /// it on every launch would make the accordion pointless.
    var collapsedInboxGroups: Set<String> = []

    // Hosts
    /// The host a review session is on: the workspace, drafts, conversation
    /// and AI panels all read this one.
    var githubHost: ForgeHost = .dotCom
    /// Every host the reviewer has configured, so the watch-a-project
    /// picker can browse a host without the app having to be switched to
    /// it first.
    ///
    /// Persisted rather than derived. The set of hosts *in use* can be
    /// derived from the watchlist — `DashboardModel.syncHosts` does exactly
    /// that — but a host with nothing watched on it yet would then be
    /// invisible to the picker, which is the one place a reviewer goes to
    /// watch their first project on a new host.
    var knownHosts: [ForgeHost] = []
    var recentPRs: [String] = []

    // Watchlist polling and alerts
    var pollIntervalSeconds: Int = 300
    var pollJitterFraction: Double = 0.2
    var maxPollIntervalSeconds: Int = 1800
    var pollingEnabled: Bool = true
    var inAppActivityEnabled: Bool = true
    /// The master switch for system notifications, kept at the top level
    /// because it predates the rest of the notification settings and older
    /// stored blobs carry it. `notifications.enabled` is the same switch:
    /// they are kept in step by `AppSettings`'s decoder and by the settings
    /// pane, so neither reader has to know which one is authoritative.
    var nativeNotificationsEnabled: Bool = false
    /// Jira, when the team runs one: where it lives and how a key is
    /// recognised. Off until configured.
    var issueTracker = IssueTrackerSettings()

    /// Everything else about being interrupted — which events, whose pull
    /// requests, sound, grouping, quiet hours.
    var notifications = NotificationPreferences()

    // AI
    /// Apple Intelligence by default: it needs no key, no install, and no
    /// network, and where the Mac cannot serve it the AI panel says so and
    /// analysis falls back to the local heuristic analyzer. A stored blob
    /// keeps whatever the reviewer already chose — this only affects a fresh
    /// install.
    var aiProviderID: String = "apple-intelligence"
    var aiModel: String = ""
    var aiReasoningEffort: String = "medium"
    var autoAnalyzeOnOpen: Bool = true
    var autoAnalyzeMaxFiles: Int = 30
    /// Legacy local-model fields, still used by the Ollama provider.
    /// How long a command-line agent may stay silent before Reviewrr gives
    /// up on it. Idle time, not total run time — a long analysis is normal.
    var aiAgentIdleTimeoutSeconds: Double = 180
    var localModelEndpoint: String = "http://localhost:11434"
    var localModelName: String = "llama3.1"

    init() {}

    private static let defaultsKey = "reviewrr.settings"

    static func load() -> AppSettings {
        guard
            let data = UserDefaults.standard.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return AppSettings()
        }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    mutating func addRecent(_ key: String) {
        recentPRs.removeAll { $0 == key }
        recentPRs.insert(key, at: 0)
        if recentPRs.count > 15 {
            recentPRs = Array(recentPRs.prefix(15))
        }
    }

    // MARK: - Forward-compatible decoding

    enum CodingKeys: String, CodingKey {
        case appearance, diffLayout, wordWrap, hiddenFileCategories, startOnDashboard
        case keychainAccessDeclined
        case textSize, collapsedInboxGroups
        case githubHost, knownHosts, recentPRs
        case pollIntervalSeconds, pollJitterFraction, maxPollIntervalSeconds
        case pollingEnabled, inAppActivityEnabled, nativeNotificationsEnabled
        case notifications, issueTracker
        case aiProviderID, aiModel, aiReasoningEffort, autoAnalyzeOnOpen, autoAnalyzeMaxFiles
        case localModelEndpoint, localModelName
        case aiAgentIdleTimeoutSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        appearance = value(.appearance, defaults.appearance)
        diffLayout = value(.diffLayout, defaults.diffLayout)
        wordWrap = value(.wordWrap, defaults.wordWrap)
        hiddenFileCategories = value(.hiddenFileCategories, defaults.hiddenFileCategories)
        startOnDashboard = value(.startOnDashboard, defaults.startOnDashboard)
        keychainAccessDeclined = value(.keychainAccessDeclined, defaults.keychainAccessDeclined)
        textSize = value(.textSize, defaults.textSize)
        collapsedInboxGroups = value(.collapsedInboxGroups, defaults.collapsedInboxGroups)
        githubHost = value(.githubHost, defaults.githubHost)
        knownHosts = value(.knownHosts, defaults.knownHosts)
        recentPRs = value(.recentPRs, defaults.recentPRs)
        pollIntervalSeconds = value(.pollIntervalSeconds, defaults.pollIntervalSeconds)
        pollJitterFraction = value(.pollJitterFraction, defaults.pollJitterFraction)
        maxPollIntervalSeconds = value(.maxPollIntervalSeconds, defaults.maxPollIntervalSeconds)
        pollingEnabled = value(.pollingEnabled, defaults.pollingEnabled)
        inAppActivityEnabled = value(.inAppActivityEnabled, defaults.inAppActivityEnabled)
        nativeNotificationsEnabled = value(.nativeNotificationsEnabled, defaults.nativeNotificationsEnabled)
        notifications = value(.notifications, defaults.notifications)
        issueTracker = value(.issueTracker, defaults.issueTracker)
        // The two switches are one switch. A blob from a build that only had
        // the flag carries the reviewer's real answer there, so it wins when
        // the nested preferences were never written; afterwards they agree.
        if (try? container.decodeIfPresent(NotificationPreferences.self, forKey: .notifications)) ?? nil == nil {
            notifications.enabled = nativeNotificationsEnabled
        } else {
            nativeNotificationsEnabled = notifications.enabled
        }
        aiProviderID = value(.aiProviderID, defaults.aiProviderID)
        aiModel = value(.aiModel, defaults.aiModel)
        aiReasoningEffort = value(.aiReasoningEffort, defaults.aiReasoningEffort)
        autoAnalyzeOnOpen = value(.autoAnalyzeOnOpen, defaults.autoAnalyzeOnOpen)
        autoAnalyzeMaxFiles = value(.autoAnalyzeMaxFiles, defaults.autoAnalyzeMaxFiles)
        aiAgentIdleTimeoutSeconds = value(.aiAgentIdleTimeoutSeconds, defaults.aiAgentIdleTimeoutSeconds)
        localModelEndpoint = value(.localModelEndpoint, defaults.localModelEndpoint)
        localModelName = value(.localModelName, defaults.localModelName)
    }
}
