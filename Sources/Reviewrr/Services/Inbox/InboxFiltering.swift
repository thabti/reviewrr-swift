import Foundation

enum InboxGrouping: String, CaseIterable, Equatable, Identifiable {
    case byProject, byReviewerBucket

    var id: String { rawValue }
    var label: String { self == .byProject ? "By project" : "By reviewer" }
}

enum InboxSortField: String, CaseIterable, Equatable {
    case updated, created
}

/// Reviewer-facing filter criteria for the inbox. Every field defaults to
/// "no restriction" so a freshly constructed filter shows everything.
struct InboxFilter: Equatable {
    /// The inbox opens on work that is still live. Merged and closed PRs
    /// stay one filter click away — they are never removed from the cache —
    /// but a reviewer's morning question is "what needs me now", and
    /// answering it with a list led by last week's merges is noise.
    ///
    /// Drafts count as open here for the same reason GitHub's own Open tab
    /// includes them: a draft is still live work you may be asked about.
    static let defaultStates: Set<InboxPRState> = Set(InboxPRState.allCases.filter(\.isLive))

    var states: Set<InboxPRState> = InboxFilter.defaultStates
    /// Watched-project keys to restrict the inbox to. Empty means every
    /// watched project, which is the default cross-repository view.
    var projectKeys: Set<String> = []
    var localStatuses: Set<LocalReviewStatus> = []
    var author: String = ""
    var label: String = ""
    var reviewRequestedOfMeOnly: Bool = false
    var updatedWithinDays: Int?
    var searchText: String = ""

    /// Whether the reviewer has narrowed anything *beyond* the default view.
    /// Drives the "filters are active" affordance and the difference between
    /// an empty inbox and an over-filtered one, so it compares against the
    /// default rather than against no states at all.
    var isEmpty: Bool {
        states == InboxFilter.defaultStates && projectKeys.isEmpty && localStatuses.isEmpty && author.isEmpty && label.isEmpty
            && !reviewRequestedOfMeOnly && updatedWithinDays == nil && searchText.isEmpty
    }
}

/// Pure filtering, sorting, and grouping over `InboxPR` rows — no network,
/// no view types, so it's directly unit-testable.
enum InboxFiltering {
    /// Applies every active criterion in `filter`. `localStatus` maps a
    /// row's key to its locally tracked status; a row not yet in the map
    /// is treated as `.none`.
    static func apply(
        _ filter: InboxFilter,
        to rows: [InboxPR],
        localStatus: [String: LocalPRStatus],
        now: Date = Date()
    ) -> [InboxPR] {
        rows.filter { row in
            if !filter.states.isEmpty, !filter.states.contains(row.state) { return false }

            if !filter.projectKeys.isEmpty {
                let key = WatchedProject.makeKey(host: row.host, owner: row.owner, repo: row.repo)
                if !filter.projectKeys.contains(key) { return false }
            }

            let status = localStatus[row.statusKey]?.status ?? .none
            if !filter.localStatuses.isEmpty, !filter.localStatuses.contains(status) { return false }

            if !filter.author.isEmpty,
               row.authorLogin.localizedCaseInsensitiveCompare(filter.author) != .orderedSame {
                return false
            }

            if !filter.label.isEmpty,
               !row.labels.contains(where: { $0.name.localizedCaseInsensitiveCompare(filter.label) == .orderedSame }) {
                return false
            }

            if filter.reviewRequestedOfMeOnly, !row.buckets.contains(.needsReview) { return false }

            if let days = filter.updatedWithinDays {
                let threshold = now.addingTimeInterval(-Double(days) * 86400)
                if row.updatedAt < threshold { return false }
            }

            if !filter.searchText.isEmpty {
                let needle = filter.searchText.lowercased()
                let haystacks: [String] = [
                    String(row.number), row.title, row.authorLogin, row.repoNameWithOwner, row.headRef ?? "",
                ] + row.labels.map(\.name)
                guard haystacks.contains(where: { $0.lowercased().contains(needle) }) else { return false }
            }

            return true
        }
    }

    static func sorted(_ rows: [InboxPR], field: InboxSortField = .updated) -> [InboxPR] {
        switch field {
        case .updated: return rows.sorted { $0.updatedAt > $1.updatedAt }
        case .created: return rows.sorted { $0.createdAt > $1.createdAt }
        }
    }

    struct ProjectGroup: Identifiable {
        let project: WatchedProject
        let rows: [InboxPR]
        var id: String { project.key }
    }

    /// Groups by project, with projects ordered by most recently opened
    /// (falling back to when they were added) and each project's rows
    /// sorted by latest activity — the product's default inbox order.
    static func groupedByProject(_ rows: [InboxPR], projects: [WatchedProject], sortField: InboxSortField = .updated) -> [ProjectGroup] {
        let byRepo = Dictionary(grouping: rows) { $0.repoNameWithOwner }
        let ordered = projects.sorted { lhs, rhs in
            (lhs.lastOpenedAt ?? lhs.addedAt) > (rhs.lastOpenedAt ?? rhs.addedAt)
        }
        return ordered.map { project in
            ProjectGroup(project: project, rows: sorted(byRepo[project.nameWithOwner] ?? [], field: sortField))
        }
    }

    struct BucketGroup: Identifiable {
        let bucket: InboxReviewerBucket
        let rows: [InboxPR]
        var id: String { bucket.rawValue }
    }

    static func groupedByReviewerBucket(_ rows: [InboxPR], sortField: InboxSortField = .updated) -> [BucketGroup] {
        InboxReviewerBucket.allCases.map { bucket in
            BucketGroup(bucket: bucket, rows: sorted(rows.filter { $0.buckets.contains(bucket) }, field: sortField))
        }
    }
}
