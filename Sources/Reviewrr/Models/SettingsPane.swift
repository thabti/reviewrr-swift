import Foundation

/// The panes of the configuration screen, in the order they are listed.
///
/// A model type rather than a view enum because the command palette, the menu
/// bar and the deep links into settings ("configure a provider", "notification
/// permission was refused") all need to name a pane, and none of them should
/// have to import the view that draws it.
enum SettingsPane: String, CaseIterable, Identifiable, Codable, Sendable {
    case account
    case general
    case notifications
    case integrations
    case watchlist
    case ai
    case data

    var id: String { rawValue }

    var label: String {
        switch self {
        case .account: return "Account"
        case .general: return "General"
        case .notifications: return "Notifications"
        case .integrations: return "Integrations"
        case .watchlist: return "Watchlist"
        case .ai: return "AI"
        case .data: return "Data"
        }
    }

    var systemImage: String {
        switch self {
        case .account: return "person.crop.circle"
        case .general: return "gearshape"
        case .notifications: return "bell.badge"
        case .integrations: return "link"
        case .watchlist: return "rectangle.stack"
        case .ai: return "sparkles"
        case .data: return "externaldrive"
        }
    }

    /// The sentence under the pane's heading, saying what the pane is for.
    ///
    /// Longer than `summary`, which has one sidebar line to work with.
    var detail: String {
        switch self {
        case .account: return "Where Reviewrr signs in, and with what."
        case .general: return "How the app looks, and how the diff reads."
        case .notifications: return "What is worth interrupting you for, and when."
        case .integrations: return "Turn issue keys in a pull request into links to your tracker."
        case .watchlist: return "How often watched projects are checked for activity."
        case .ai: return "Which model answers, and how much of the pull request it reads."
        case .data: return "What Reviewrr keeps on this Mac, and how to clear it."
        }
    }

    /// One line under the pane's name in the sidebar. A settings sidebar of
    /// six bare nouns makes the reviewer click all six to find the one they
    /// want; this is the cheapest way to make the list answerable at a
    /// glance.
    var summary: String {
        switch self {
        case .account: return "Hosts, tokens, sign-in"
        case .general: return "Appearance, diff layout, text size"
        case .notifications: return "What interrupts you, and when"
        case .integrations: return "Jira issue links"
        case .watchlist: return "Polling and watched projects"
        case .ai: return "Provider, model, analysis"
        case .data: return "Local storage and caches"
        }
    }
}
