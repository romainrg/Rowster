import AppKit
import SwiftUI

/// Renders the real app views offscreen into PNGs (no screen capture, so no Screen Recording permission).
/// Usage: `RowsterScreenshots <output dir> [scene filter] [--language fr] [--appearance light|dark]`.
@main
enum ScreenshotTool {
    @MainActor
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        var positional: [String] = []
        var language: String?
        var appearances = ["light", "dark"]
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--language" where index + 1 < arguments.count:
                language = arguments[index + 1]
                index += 1
            case "--appearance" where index + 1 < arguments.count:
                appearances = [arguments[index + 1]]
                index += 1
            default:
                positional.append(arguments[index])
            }
            index += 1
        }
        UserDefaults.standard.set([language ?? "en"], forKey: "AppleLanguages")
        UserDefaults.standard.set(language == "fr" ? "fr_FR" : "en_US", forKey: "AppleLocale")
        NSApplication.shared.setActivationPolicy(.accessory)

        let output = URL(fileURLWithPath: positional.first ?? "build/screenshots", isDirectory: true)
        let filter = positional.count > 1 ? positional[1] : ""
        let suffix = language.flatMap { $0 == "en" ? nil : "-\($0)" } ?? ""
        let scenes = ScreenshotScenes.all.filter { filter.isEmpty || $0.name.contains(filter) }
        guard !scenes.isEmpty else {
            FileHandle.standardError.write(Data("No scene matches '\(filter)'\n".utf8))
            exit(1)
        }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for scene in scenes {
                for appearance in appearances {
                    let url = output.appendingPathComponent("\(scene.name)\(suffix)-\(appearance).png")
                    try await render(scene, dark: appearance == "dark", to: url)
                    print("Wrote \(url.path)")
                }
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Render failed: \(error)\n".utf8))
            exit(1)
        }
    }

    struct RenderError: Error { let message: String }

    @MainActor
    private static func render(_ scene: ScreenshotScene, dark: Bool, to url: URL, scale: CGFloat = 2) async throws {
        let size = scene.size
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let controller = NSHostingController(rootView: await scene.make())
        controller.sceneBridgingOptions = .all
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled]
        window.appearance = appearance
        // The scene size is the content size: the title bar is added around it, as in the app.
        window.setContentSize(size)
        window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        let hosting = controller.view
        for _ in 0..<8 {
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
        }

        let frameView = hosting.superview ?? hosting
        let frameSize = frameView.bounds.size
        window.title = scene.title
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(frameSize.width * scale), pixelsHigh: Int(frameSize.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw RenderError(message: "bitmap \(size)") }
        rep.size = frameSize
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        window.orderOut(nil)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw RenderError(message: "PNG \(url.lastPathComponent)")
        }
        try png.write(to: url)
    }
}
