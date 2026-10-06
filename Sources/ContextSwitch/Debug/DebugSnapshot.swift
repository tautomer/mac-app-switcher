#if DEBUG
import AppKit
import ScreenCaptureKit
import SwiftUI

/// Debug builds only: writes PNGs of this app's own windows (sheets
/// included) to /tmp/contextswitch-snapshots, for reviewing UI changes.
/// Capturing your own process's windows needs no Screen Recording
/// permission.
@MainActor
enum DebugSnapshot {
    static let directory = URL(fileURLWithPath: "/tmp/contextswitch-snapshots")

    static func captureAll() async {
        guard #available(macOS 14.4, *) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let content = try await SCShareableContent.currentProcess
            // Layer 0 = normal windows and sheets (skips menu bar/wallpaper).
            // Not filtered on isOnScreen: windows on another Space (e.g.
            // while a full-screen app is frontmost) can still be captured.
            for window in content.windows where window.windowLayer == 0 && window.frame.width > 120 && window.frame.height > 120 {
                let config = SCStreamConfiguration()
                config.width = Int(window.frame.width * 2)
                config.height = Int(window.frame.height * 2)
                config.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: window),
                    configuration: config
                )
                let title = window.title.flatMap { $0.isEmpty ? nil : $0 } ?? "window-\(window.windowID)"
                let url = directory.appendingPathComponent("\(title).png")
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
                NSLog("DebugSnapshot: wrote %@", url.path)
            }
        } catch {
            NSLog("DebugSnapshot: %@", String(describing: error))
        }
    }
}

struct DebugCommands: Commands {
    var body: some Commands {
        CommandMenu("Debug") {
            Button("Capture Windows") {
                Task { await DebugSnapshot.captureAll() }
            }
        }
    }
}
#endif
