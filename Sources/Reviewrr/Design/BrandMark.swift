import SwiftUI

/// The service a settings card is about, drawn as its own mark.
///
/// ## Where the artwork comes from
///
/// Each case looks for an image in the asset catalog first — drop
/// `brand-github`, `brand-gitlab` or `brand-jira` in
/// `Resources/Assets.xcassets` (the official SVG or PDF from the vendor's
/// press kit, as a single-scale vector) and it is used verbatim, at any
/// size, in either appearance.
///
/// Without that asset each case draws a vector fallback. GitLab's and
/// Jira's marks are geometric — triangles and chevrons — so those are
/// faithful. GitHub's is a detailed silhouette that cannot be reproduced
/// honestly by hand, so it falls back to a monogram on GitHub's brand
/// black rather than to an invented cat: a wrong logo is worse than an
/// obvious placeholder.
enum Brand: String, CaseIterable, Sendable {
    case github
    case gitlab
    case jira

    var assetName: String { "brand-\(rawValue)" }

    var displayName: String {
        switch self {
        case .github: return "GitHub"
        case .gitlab: return "GitLab"
        case .jira: return "Jira"
        }
    }

    /// The vendor's own primary colour, for the tile behind the mark.
    var tint: Color {
        switch self {
        case .github: return Color(red: 0.13, green: 0.15, blue: 0.17)
        case .gitlab: return Color(red: 0.99, green: 0.42, blue: 0.16)
        case .jira: return Color(red: 0.16, green: 0.44, blue: 0.94)
        }
    }

    static func forge(_ forge: Forge) -> Brand {
        switch forge {
        case .github: return .github
        case .gitlab: return .gitlab
        }
    }
}

/// A brand's mark at a given size, from the asset catalog when it is there
/// and a drawn fallback when it is not.
struct BrandGlyph: View {
    let brand: Brand
    var size: CGFloat = 24

    var body: some View {
        Group {
            if let image = NSImage(named: brand.assetName) {
                Image(nsImage: image)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var fallback: some View {
        switch brand {
        case .gitlab:
            TanukiMark().fill(brand.tint)
        case .jira:
            JiraMark().fill(brand.tint)
        case .github:
            // A monogram, not a hand-drawn Octocat. See `Brand`.
            Text("GH")
                .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(brand.tint, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
        }
    }
}

/// GitLab's tanuki: a fox face built from triangles, which is exactly how
/// the official mark is constructed — so this is a faithful reproduction
/// rather than an impression of one.
private struct TanukiMark: Shape {
    func path(in rect: CGRect) -> Path {
        // Normalised on a 100×97 grid, then scaled — the proportions of the
        // published mark.
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x / 100, y: rect.minY + rect.height * y / 97)
        }

        var path = Path()

        // Centre wedge, from the two inner peaks down to the chin.
        path.move(to: point(50, 97))
        path.addLine(to: point(31, 38))
        path.addLine(to: point(69, 38))
        path.closeSubpath()

        // Left outer wedge and its spike.
        path.move(to: point(50, 97))
        path.addLine(to: point(2, 38))
        path.addLine(to: point(31, 38))
        path.closeSubpath()

        path.move(to: point(2, 38))
        path.addLine(to: point(16, 2))
        path.addLine(to: point(31, 38))
        path.closeSubpath()

        // Right outer wedge and its spike, mirrored.
        path.move(to: point(50, 97))
        path.addLine(to: point(98, 38))
        path.addLine(to: point(69, 38))
        path.closeSubpath()

        path.move(to: point(98, 38))
        path.addLine(to: point(84, 2))
        path.addLine(to: point(69, 38))
        path.closeSubpath()

        return path
    }
}

/// Jira's mark: a chevron pointing up-right, with a second chevron nested
/// behind it — the two-arrow diamond of the published logo.
private struct JiraMark: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x / 100, y: rect.minY + rect.height * y / 100)
        }

        var path = Path()

        // The forward chevron: top-right corner folding down to the middle.
        path.move(to: point(50, 0))
        path.addLine(to: point(100, 50))
        path.addLine(to: point(50, 100))
        path.addLine(to: point(28, 78))
        path.addLine(to: point(56, 50))
        path.addLine(to: point(28, 22))
        path.closeSubpath()

        // The one behind it, offset left and clipped by the first.
        path.move(to: point(22, 16))
        path.addLine(to: point(44, 38))
        path.addLine(to: point(22, 60))
        path.addLine(to: point(0, 38))
        path.closeSubpath()

        return path
    }
}

/// A brand's mark on a large rounded tile — the identity element every
/// settings card leads with.
///
/// Big on purpose. A settings pane that opens with a 46pt mark and a name
/// answers "what is this screen about" before any text is read, which is
/// what a reviewer arriving from a sidebar list actually needs.
struct BrandTile: View {
    let brand: Brand
    var isActive: Bool = true
    var size: CGFloat = 46

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(
                LinearGradient(
                    colors: isActive
                        ? [brand.tint.opacity(0.28), brand.tint.opacity(0.10)]
                        : [Color.secondary.opacity(0.16), Color.secondary.opacity(0.06)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder((isActive ? brand.tint : .secondary).opacity(0.35))
            )
            .overlay(
                BrandGlyph(brand: brand, size: size * 0.55)
                    .opacity(isActive ? 1 : 0.45)
                    .grayscale(isActive ? 0 : 1)
            )
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The same tile for a screen with no vendor behind it — notifications,
/// data, appearance — so every settings pane opens the same way.
struct SettingsTile: View {
    let systemImage: String
    var tint: Color = Theme.accent
    var isActive: Bool = true
    var size: CGFloat = 46

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(
                LinearGradient(
                    colors: isActive
                        ? [tint.opacity(0.28), tint.opacity(0.10)]
                        : [Color.secondary.opacity(0.16), Color.secondary.opacity(0.06)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder((isActive ? tint : .secondary).opacity(0.35))
            )
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(isActive ? tint : Color.secondary)
            )
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
