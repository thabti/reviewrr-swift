import Foundation

extension ForgeHost {
    /// Web URL for one file at one ref, for "open this file in the browser".
    ///
    /// The sibling of `webURL(owner:repo:number:)`, and here for the same
    /// reason: GitLab's path grammar is not GitHub's. `…/blob/<ref>/<path>`
    /// is a GitHub URL. On GitLab a project's own routes live under `/-/`,
    /// so the file is at `…/-/blob/<ref>/<path>` — the dash-less form is a
    /// legacy route GitLab has spent several majors removing, and a link
    /// that depends on a redirect still working is a link that breaks on the
    /// next upgrade.
    ///
    /// Built with `appendingPathComponent` rather than interpolation because
    /// a path is the one part of these URLs that carries arbitrary text: a
    /// file called `My File.swift` interpolates into a string that
    /// `URL(string:)` rejects outright, and one containing `#` silently
    /// becomes a fragment. Slashes inside `owner` (a GitLab group path) and
    /// inside `path` survive as separators, which is what both need.
    ///
    /// Declared in its own file rather than added to `Forge.swift` so
    /// parallel tracks do not collide in one file; it belongs next to
    /// `webURL`.
    func blobURL(owner: String, repo: String, ref: String, path: String) -> URL? {
        guard !owner.isEmpty, !repo.isEmpty, !ref.isEmpty, !path.isEmpty else { return nil }
        var url = webBaseURL
            .appendingPathComponent(owner)
            .appendingPathComponent(repo)
        if forge == .gitlab { url = url.appendingPathComponent("-") }
        return url
            .appendingPathComponent("blob")
            .appendingPathComponent(ref)
            .appendingPathComponent(path)
    }
}
