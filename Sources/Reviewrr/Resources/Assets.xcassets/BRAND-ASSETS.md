# Brand marks

`brand-github`, `brand-gitlab` and `brand-jira` are empty image sets, ready for
each vendor's official artwork.

## Dropping in the real logos

1. Get the mark from the vendor's own press kit — GitHub's Octocat/Invertocat,
   GitLab's tanuki, Atlassian's Jira mark. Take the **single-colour or full-colour
   mark**, not the wordmark: these render at 13–26pt beside text.
2. Prefer a **PDF or SVG**. Each set already has
   `preserves-vector-representation: true`, so one vector file scales to every
   size and both appearances.
3. Drop the file into the matching `.imageset` folder and add it to the
   `images` array in that folder's `Contents.json` as `"filename": "…"`.

`BrandGlyph` picks the asset up automatically — `NSImage(named:)` is tried first
and the drawn fallback is only used when the asset is absent. No code changes.

## What the fallbacks are

- **GitLab** — the tanuki, drawn as the five triangles the official mark is
  actually built from. Faithful.
- **Jira** — the two-chevron diamond. Faithful enough at these sizes.
- **GitHub** — a `GH` monogram on GitHub's brand black. The Octocat is a
  detailed silhouette that cannot be reproduced honestly by hand, and an
  invented cat would be worse than an obvious placeholder. This is the one
  worth replacing with the real asset.

## Trademarks

These are third-party trademarks, used to identify the service each screen
connects to. Follow each vendor's brand guidelines — do not recolour or distort
the marks, and do not imply endorsement.
