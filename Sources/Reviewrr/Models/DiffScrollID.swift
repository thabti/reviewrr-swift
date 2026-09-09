import Foundation

// Scroll-target identities for the diff pane's children.
//
// Plain string builders, in Models rather than in the views that use them, for
// two reasons: `WorkspaceModel` stores one of them per file as the reviewer's
// remembered place, so the id is model state; and they run thousands of times
// a second while scrolling, which is a claim the test bundle can only check if
// it can see them.

/// Scroll-target id for a file's sticky header.
func diffFileScrollID(_ path: String) -> String { "file:\(path)" }

/// Scroll ids for the two non-row children of a file's content, so the flat
/// layout the pane scrolls through has an identity for every child.
func diffHunkScrollID(path: String, hunkIndex: Int) -> String { "\(path)#h\(hunkIndex)#header" }
func diffGapScrollID(path: String, hunkIndex: Int) -> String { "\(path)#h\(hunkIndex)#gap" }

/// Scroll-target id for one paired diff row. See `DiffNavigator.rowIdentity`
/// for why (hunk index, row id) — not the line number alone — is the key.
func diffRowScrollID(path: String, hunkIndex: Int, rowID: Int) -> String {
    "\(path)#h\(hunkIndex)#\(rowID)"
}
