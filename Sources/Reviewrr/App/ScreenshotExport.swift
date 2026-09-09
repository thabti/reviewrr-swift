#if DEBUG
import AppKit
import SwiftUI

/// Writes a PNG of the app's own window, for the README.
///
/// ## Why not a screen capture, and why not `ImageRenderer`
///
/// `screencapture` and `CGWindowListCreateImage` both need macOS Screen
/// Recording permission, which a build machine or CI runner does not have.
///
/// `ImageRenderer` needs no permission but cannot draw this interface: it
/// renders a SwiftUI hierarchy in isolation, and every AppKit-backed view
/// in it — `List`, `TextField`, `ScrollView` with lazy content — comes out
/// as a yellow "unsupported" placeholder. The first attempt produced a
/// picture with an empty diff pane and a solid yellow file tree.
///
/// A view drawing *itself* is neither of those things. `cacheDisplay(in:to:)`
/// asks the real window's real view hierarchy to render into a bitmap — the
/// same drawing code that puts pixels on screen, with no display server and
/// no permission involved. So the picture is the actual app, and it can be
/// regenerated whenever the layout changes rather than going stale.
///
/// It always renders the **demo pull request**: the fixture is synthetic, so
/// a published screenshot cannot leak a repository name, title, author or
/// hostname from whoever ran it.
///
/// `DEBUG` only — compiled out of a release build.
///
/// ```
/// make screenshot
/// Reviewrr.app --export-screenshot out.png [--light]
/// ```
@MainActor
enum ScreenshotExport {
    static let flag = "--export-screenshot"

    static var requestedPath: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard
            let index = arguments.firstIndex(of: flag),
            index + 1 < arguments.count
        else { return nil }
        return arguments[index + 1]
    }

    static var wantsLightAppearance: Bool {
        ProcessInfo.processInfo.arguments.contains("--light")
    }

    /// Loads the demo, waits for the window to settle, writes the file, and
    /// terminates.
    ///
    /// The wait is not a guess at a fixed duration: it polls until the
    /// window exists, is sized, and the diff has actually laid out rows,
    /// with a ceiling so a failure exits rather than hanging a build.
    static func run(model: AppModel, path: String) async {
        // Through the app's own setting, not `NSApp.appearance`: the scene
        // applies `preferredColorScheme` from `AppSettings`, which wins over
        // an appearance set on the application afterwards — the first
        // attempt asked for dark and rendered light.
        model.settings.appearance = wantsLightAppearance ? .light : .dark

        model.loadDemo()
        // Hidden so the diff pane takes the full remaining width — see
        // `pngOfDiffPane` for why the inspector cannot be captured.
        model.isInspectorPresented = false
        model.selectedFile = model.files.first?.filename
        if let first = model.selectedFile {
            await model.ensureParsed(first)
        }

        guard let window = await settledWindow() else {
            fail("no window to draw after waiting")
            return
        }

        // The app's own default size, so the proportions in the README are
        // the proportions a reviewer gets.
        window.setContentSize(NSSize(width: 1_440, height: 900))
        window.center()

        // One more turn of the run loop after resizing, so the split view
        // and the diff's lazy rows lay out at the final width before the
        // bitmap is taken.
        for _ in 0..<8 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(120))
        }

        guard let png = pngOfDiffPane(window) else {
            fail("the window produced no bitmap")
            return
        }

        do {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try png.write(to: url, options: .atomic)
            note("wrote \(path) (\(png.count / 1_024) KB)")
            exit(0)
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// The main window, once it exists and has a non-trivial size.
    private static func settledWindow() async -> NSWindow? {
        for _ in 0..<80 {
            if let window = NSApp.windows.first(where: { $0.contentView != nil && $0.frame.width > 400 }) {
                return window
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// The diff pane, drawn by the view hierarchy itself.
    ///
    /// ## What could not be captured, and why the image is cropped
    ///
    /// Neither `cacheDisplay(in:to:)` nor `CALayer.render(in:)` can draw
    /// this window whole. The diff pane comes out faithful — real syntax
    /// highlighting, word-level diff, inline threads — but the file tree is
    /// a `List` and the inspector sits on a material, and both are composited
    /// by the window server rather than drawn by the view. `cacheDisplay`
    /// left the sidebar blank and the inspector as uninitialised memory;
    /// `CALayer.render` left them the same and flipped the result, because
    /// its context is bottom-left origin.
    ///
    /// Rather than publish a picture with two broken regions, or fake them,
    /// the export hides the inspector so the diff takes the full width and
    /// crops the sidebar's column away. What is left is real, and it is the
    /// surface the app is actually for.
    private static func pngOfDiffPane(_ window: NSWindow) -> Data? {
        guard let view = window.contentView else {
            note("no content view")
            return nil
        }
        let bounds = view.bounds
        note("content view bounds \(Int(bounds.width))x\(Int(bounds.height))")
        guard bounds.width > sidebarWidth + 200, bounds.height > 1 else {
            note("window too small to crop a diff pane out of")
            return nil
        }

        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            note("no caching rep")
            return nil
        }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)

        guard let full = rep.cgImage else {
            note("rep produced no CGImage")
            return nil
        }
        // The rep is in pixels and the frame in points, so the crop scales.
        let scale = CGFloat(full.width) / bounds.width
        let crop = CGRect(
            x: sidebarWidth * scale,
            y: 0,
            width: (bounds.width - sidebarWidth) * scale,
            height: bounds.height * scale
        )
        guard let cropped = full.cropping(to: crop) else {
            note("crop \(crop) failed against \(full.width)x\(full.height)")
            return nil
        }

        let out = NSBitmapImageRep(cgImage: cropped)
        out.size = NSSize(width: CGFloat(cropped.width) / scale, height: CGFloat(cropped.height) / scale)
        return out.representation(using: .png, properties: [:])
    }

    /// The sidebar column's width, cropped off the leading edge. Matches the
    /// `ideal` in `RootView`'s `navigationSplitViewColumnWidth`, plus the
    /// divider.
    private static let sidebarWidth: CGFloat = 311

    /// stderr *and* a file: launched through LaunchServices (the only way
    /// the SwiftUI scene actually appears), the process has no terminal to
    /// write to, so a silent failure would be undiagnosable.
    private static func note(_ message: String) {
        let line = "screenshot: \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        let log = URL(fileURLWithPath: "/tmp/reviewrr-screenshot.log")
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: log)
        }
    }

    private static func fail(_ message: String) {
        note(message)
        exit(1)
    }
}
#endif
