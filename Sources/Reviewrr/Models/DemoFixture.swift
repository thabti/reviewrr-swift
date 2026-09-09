import Foundation

/// A bundled pull request so the workspace can be seen without any GitHub
/// token or network access.
///
/// The fixture is deliberately varied rather than minimal: it carries a
/// source change, a test, config, docs, a migration, a generated file, a
/// lock file, a rename, a deletion, and a binary — because file
/// classification, triage filters, review progress, and the "we cannot show
/// this file" paths are only really exercised by a diff that contains all of
/// them. Extra PRs exist so the dashboard has an inbox to render offline.
enum DemoFixture {
    static let reference = PRReference(owner: "acme", repo: "web-app", number: 482)

    /// The file list the review workspace opens on: the bundled fixture,
    /// unless `REVIEWRR_STRESS` asked for a synthetic pull request big enough
    /// to benchmark scrolling against.
    static var reviewFiles: [PRFile] { StressFixture.isEnabled ? StressFixture.files : files }

    static let labels: [GitHubLabel] = [
        GitHubLabel(id: 1, name: "feature", color: "0e8a16"),
        GitHubLabel(id: 2, name: "needs-review", color: "fbca04"),
        GitHubLabel(id: 3, name: "backend", color: "1d76db"),
    ]

    static let pullRequest = PullRequest(
        id: 1, number: 482, title: "Add teammate invitations with roles",
        body: """
        Endpoints to create, list, and accept invitations; token generation; the invitation email; \
        and the admin-only permission gate.

        - `POST /orgs/:id/invitations` creates an invitation and sends the email
        - `POST /invitations/:token/accept` joins the org
        - Only org admins can invite; enforced in `permissions.ts`

        Token expiry is fixed at seven days for now — see the open question in the discussion.
        """,
        state: .open, draft: false, merged: false, mergeableState: "clean",
        user: GitHubUser(login: "demo-author", avatarUrl: nil),
        head: .init(ref: "invitations", sha: "demo-head-sha"),
        base: .init(ref: "main", sha: "demo-base-sha"),
        additions: 214, deletions: 57, changedFiles: 11, commits: 6, comments: 2, reviewComments: 3,
        createdAt: Date(timeIntervalSinceNow: -86_400 * 2), updatedAt: Date(timeIntervalSinceNow: -3_600),
        htmlUrl: "https://github.com/acme/web-app/pull/482", labels: labels,
        mergeable: true,
        requestedReviewers: [GitHubUser(login: "reviewer-three", avatarUrl: nil)]
    )

    /// Other open PRs across watched projects, so an offline dashboard has
    /// more than one row to group, filter, and sort.
    static let otherPullRequests: [PullRequest] = [
        PullRequest(
            id: 2, number: 118, title: "Fix payment retry backoff on 429",
            body: "Retries were doubling from 1s with no cap, so a rate-limited provider produced a 4-minute stall.",
            state: .open, draft: false, merged: false, mergeableState: "blocked",
            user: GitHubUser(login: "ahmed", avatarUrl: nil),
            head: .init(ref: "retry-backoff", sha: "demo-checkout-head"),
            base: .init(ref: "main", sha: "demo-checkout-base"),
            additions: 41, deletions: 12, changedFiles: 3, commits: 2, comments: 4, reviewComments: 2,
            createdAt: Date(timeIntervalSinceNow: -86_400 * 3), updatedAt: Date(timeIntervalSinceNow: -10_800),
            htmlUrl: "https://github.com/acme/checkout-service/pull/118",
            labels: [GitHubLabel(id: 4, name: "bug", color: "d73a4a")],
            mergeable: false
        ),
        PullRequest(
            id: 3, number: 77, title: "Introduce inventory reservation",
            body: "Reserves stock at checkout for 15 minutes so two carts cannot claim the same unit.",
            state: .open, draft: true, merged: false, mergeableState: "clean",
            user: GitHubUser(login: "omar", avatarUrl: nil),
            head: .init(ref: "reservations", sha: "demo-warehouse-head"),
            base: .init(ref: "main", sha: "demo-warehouse-base"),
            additions: 380, deletions: 24, changedFiles: 14, commits: 9, comments: 1, reviewComments: 0,
            createdAt: Date(timeIntervalSinceNow: -86_400 * 5), updatedAt: Date(timeIntervalSinceNow: -86_400),
            htmlUrl: "https://github.com/acme/warehouse/pull/77",
            labels: [GitHubLabel(id: 5, name: "architecture", color: "5319e7")]
        ),
        PullRequest(
            id: 4, number: 903, title: "Bump lockfile after dependency audit",
            body: "Routine dependency bump; no application code changes.",
            state: .closed, draft: false, merged: true, mergeableState: "unknown",
            user: GitHubUser(login: "sarah", avatarUrl: nil),
            head: .init(ref: "dep-audit", sha: "demo-mobile-head"),
            base: .init(ref: "main", sha: "demo-mobile-base"),
            additions: 1_204, deletions: 1_190, changedFiles: 1, commits: 1, comments: 0, reviewComments: 0,
            createdAt: Date(timeIntervalSinceNow: -86_400 * 8), updatedAt: Date(timeIntervalSinceNow: -86_400 * 6),
            htmlUrl: "https://github.com/acme/mobile-app/pull/903", labels: [],
            mergedAt: Date(timeIntervalSinceNow: -86_400 * 6)
        ),
    ]

    /// `owner/repo` identifiers matching `otherPullRequests`, in order,
    /// alongside this fixture's own project.
    static let projects: [(owner: String, repo: String)] = [
        ("acme", "web-app"),
        ("acme", "checkout-service"),
        ("acme", "warehouse"),
        ("acme", "mobile-app"),
    ]

    static let files: [PRFile] = [
        PRFile(
            filename: "src/server/auth/permissions.ts", previousFilename: nil, status: .modified,
            additions: 11, deletions: 3, changes: 14,
            patch: """
            @@ -20,6 +20,8 @@ export function canRemoveMember(member: Member): boolean {
               return member.role === "ADMIN"
             }

            -export function canEditBilling(member: Member): boolean {
            -  return member.role === "ADMIN"
            -}
            +export function canEditBilling(member: Member): boolean {
            +  return member.role === "ADMIN" || member.role === "BILLING"
            +}
            +
            +/**
            + * Whether the member may create or revoke teammate invitations.
            + * Restricted to org admins.
            + */
            +export function canInviteMembers(member: Member): boolean {
            +  return member.role === "ADMIN"
            +}
            """
        ),
        PRFile(
            filename: "src/server/invitations/invitationService.ts", previousFilename: nil, status: .added,
            additions: 54, deletions: 0, changes: 54,
            patch: """
            @@ -0,0 +1,26 @@
            +import { randomBytes } from "node:crypto"
            +import { db } from "../db"
            +import { sendEmail } from "../email"
            +
            +const EXPIRY_DAYS = 7
            +
            +export async function createInvitation(orgId: string, email: string) {
            +  const token = randomBytes(24).toString("hex")
            +  const expiresAt = new Date(Date.now() + EXPIRY_DAYS * 24 * 60 * 60 * 1000)
            +  await db.invitations.insert({ orgId, email, token, expiresAt })
            +  await sendInvitationEmail(email, token)
            +  return token
            +}
            +
            +export async function acceptInvitation(token: string, userId: string) {
            +  const invitation = await db.invitations.findByToken(token)
            +  if (!invitation) throw new Error("Invitation not found")
            +  if (invitation.expiresAt < new Date()) throw new Error("Invitation expired")
            +  await db.members.insert({ orgId: invitation.orgId, userId, role: "MEMBER" })
            +  await db.invitations.delete(invitation.id)
            +}
            +
            +async function sendInvitationEmail(email: string, token: string) {
            +  const url = `${process.env.APP_URL}/invitations/${token}`
            +  await sendEmail({ to: email, template: "invitation", data: { url } })
            +}
            """
        ),
        PRFile(
            filename: "src/server/invitations/__tests__/invitationService.test.ts", previousFilename: nil,
            status: .added, additions: 62, deletions: 0, changes: 62,
            patch: """
            @@ -0,0 +1,18 @@
            +import { describe, expect, it } from "vitest"
            +import { acceptInvitation, createInvitation } from "../invitationService"
            +
            +describe("createInvitation", () => {
            +  it("stores a token that expires in seven days", async () => {
            +    const token = await createInvitation("org_1", "new@example.com")
            +    expect(token).toHaveLength(48)
            +  })
            +
            +  it("rejects an expired token", async () => {
            +    await expect(acceptInvitation("expired", "user_1")).rejects.toThrow("Invitation expired")
            +  })
            +})
            """
        ),
        PRFile(
            filename: "src/server/db/migrations/0042_create_invitations.sql", previousFilename: nil,
            status: .added, additions: 14, deletions: 0, changes: 14,
            patch: """
            @@ -0,0 +1,10 @@
            +CREATE TABLE invitations (
            +  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            +  org_id UUID NOT NULL REFERENCES orgs (id) ON DELETE CASCADE,
            +  email TEXT NOT NULL,
            +  token TEXT NOT NULL UNIQUE,
            +  expires_at TIMESTAMPTZ NOT NULL,
            +  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
            +);
            +
            +CREATE INDEX invitations_org_id_idx ON invitations (org_id);
            """
        ),
        PRFile(
            filename: "config/features.yaml", previousFilename: nil, status: .modified,
            additions: 3, deletions: 1, changes: 4,
            patch: """
            @@ -8,7 +8,9 @@ features:
               billing_roles:
                 enabled: true
            -  invitations: false
            +  invitations:
            +    enabled: true
            +    expiry_days: 7
            """
        ),
        PRFile(
            filename: "docs/teams/invitations.md", previousFilename: nil, status: .added,
            additions: 26, deletions: 0, changes: 26,
            patch: """
            @@ -0,0 +1,8 @@
            +# Teammate invitations
            +
            +An org admin invites a teammate by email. The invitation carries a single-use token that
            +expires after seven days. Accepting it adds the user to the org with the `MEMBER` role.
            +
            +Revoking an invitation deletes the row; the token stops working immediately.
            """
        ),
        PRFile(
            filename: "src/server/api/generated/schema.d.ts", previousFilename: nil, status: .modified,
            additions: 41, deletions: 22, changes: 63,
            patch: """
            @@ -1,4 +1,4 @@
            -// Generated by openapi-typescript. Do not edit.
            +// Generated by openapi-typescript. Do not edit.
            @@ -118,6 +118,12 @@ export interface paths {
               "/orgs/{id}/members": {
                 get: operations["listMembers"]
               }
            +  "/orgs/{id}/invitations": {
            +    get: operations["listInvitations"]
            +    post: operations["createInvitation"]
            +  }
            """
        ),
        PRFile(
            filename: "src/client/legacy/InviteBanner.tsx", previousFilename: nil, status: .removed,
            additions: 0, deletions: 18, changes: 18,
            patch: """
            @@ -1,18 +0,0 @@
            -import { useOrg } from "../hooks/useOrg"
            -
            -export function InviteBanner() {
            -  const org = useOrg()
            -  if (!org.canInvite) return null
            -  return <div className="banner">Invite your team from the admin page.</div>
            -}
            """
        ),
        PRFile(
            filename: "public/images/invite-hero.png", previousFilename: nil, status: .added,
            additions: 0, deletions: 0, changes: 0, patch: nil
        ),
        PRFile(
            filename: "pnpm-lock.yaml", previousFilename: nil, status: .modified,
            additions: 0, deletions: 0, changes: 0, patch: nil
        ),
        PRFile(
            filename: "src/server/invitations/inviteService.ts",
            previousFilename: "src/server/orgs/inviteHelpers.ts", status: .renamed,
            additions: 3, deletions: 13, changes: 16,
            patch: """
            @@ -1,13 +1,3 @@
            -export function buildInviteUrl(token: string) {
            -  return `${process.env.APP_URL}/invitations/${token}`
            -}
            -
            -export function isExpired(expiresAt: Date) {
            -  return expiresAt < new Date()
            -}
            +export { buildInviteUrl, isExpired } from "./invitationService"
            """
        ),
    ]

    static let issueComments: [IssueComment] = [
        IssueComment(
            id: 1, user: GitHubUser(login: "reviewer-one", avatarUrl: nil),
            body: "Should the invite token expiry be configurable per org, or is 7 days a fixed policy?",
            createdAt: Date(timeIntervalSinceNow: -3_000),
            htmlUrl: "https://github.com/acme/web-app/pull/482#issuecomment-1"
        ),
        IssueComment(
            id: 2, user: GitHubUser(login: "demo-author", avatarUrl: nil),
            body: "Fixed for now — the config key is there so we can make it per-org later without a migration.",
            createdAt: Date(timeIntervalSinceNow: -2_700),
            htmlUrl: "https://github.com/acme/web-app/pull/482#issuecomment-2"
        ),
    ]

    static let reviews: [Review] = [
        Review(
            id: 1, user: GitHubUser(login: "reviewer-two", avatarUrl: nil), body: "Looks solid, one question inline.",
            state: .commented, submittedAt: Date(timeIntervalSinceNow: -2_400)
        ),
        Review(
            id: 2, user: GitHubUser(login: "reviewer-three", avatarUrl: nil),
            body: "Accepting an expired invitation should probably delete the row rather than leave it around.",
            state: .changesRequested, submittedAt: Date(timeIntervalSinceNow: -1_800)
        ),
    ]

    static let reviewComments: [ReviewComment] = [
        ReviewComment(
            id: 1, user: GitHubUser(login: "reviewer-two", avatarUrl: nil),
            body: "Consider extracting this into a shared `canManageOrg` check since it's identical to `canRemoveMember`.",
            path: "src/server/auth/permissions.ts", line: 33, originalLine: 33, side: .right, inReplyToId: nil,
            createdAt: Date(timeIntervalSinceNow: -2_200),
            htmlUrl: "https://github.com/acme/web-app/pull/482#discussion_r1"
        ),
        ReviewComment(
            id: 2, user: GitHubUser(login: "demo-author", avatarUrl: nil),
            body: "They diverge next sprint when billing gets its own role, so I'd rather keep them separate.",
            path: "src/server/auth/permissions.ts", line: 33, originalLine: 33, side: .right, inReplyToId: 1,
            createdAt: Date(timeIntervalSinceNow: -2_000),
            htmlUrl: "https://github.com/acme/web-app/pull/482#discussion_r2"
        ),
        // `line: nil` is how GitHub reports a comment whose anchor no longer
        // exists in the diff — the outdated-thread path.
        ReviewComment(
            id: 3, user: GitHubUser(login: "reviewer-three", avatarUrl: nil),
            body: "This helper moved — is anything still importing the old path?",
            path: "src/server/invitations/inviteService.ts", line: nil, originalLine: 7, side: .right,
            inReplyToId: nil,
            createdAt: Date(timeIntervalSinceNow: -1_900),
            htmlUrl: "https://github.com/acme/web-app/pull/482#discussion_r3"
        ),
    ]
}
