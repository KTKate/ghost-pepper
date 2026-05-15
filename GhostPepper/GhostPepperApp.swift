import SwiftUI
import Combine
import AppKit

class LazyUpdaterController {
    lazy var controller = UpdaterController()
}

/// Builds the menu bar glyph with a red "recording" dot, like the badge
/// Microsoft Teams shows while in a call.
///
/// `MenuBarExtra` renders its label as a *template* (monochrome) image, so a
/// SwiftUI `Circle().fill(.red)` overlay is stripped to the menu bar tint and
/// never appears red. To get a real colored dot we composite an `NSImage`
/// ourselves and mark it non-template so AppKit draws it as-is.
enum MenuBarIconRenderer {
    static func recordingBadgedIcon() -> NSImage {
        let base = NSImage(named: "MenuBarIcon") ?? NSImage(size: NSSize(width: 18, height: 18))
        let size = base.size
        let image = NSImage(size: size)

        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size)

        // Tint the template glyph to the current label color so it stays
        // legible in both light and dark menu bars.
        base.draw(in: rect)
        NSColor.labelColor.set()
        rect.fill(using: .sourceAtop)

        // Red recording dot in the bottom-trailing corner.
        let diameter = max(5, size.width * 0.36)
        let dotRect = NSRect(
            x: size.width - diameter,
            y: 0,
            width: diameter,
            height: diameter
        )
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        image.unlockFocus()

        // Non-template so the red survives the menu bar's monochrome tinting.
        image.isTemplate = false
        return image
    }
}

@main
struct GhostPepperApp: App {
    private static let automaticTerminationReason = "Ghost Pepper keeps a persistent menu bar presence."
    @StateObject private var appState = AppState()
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false
    @State private var hasInitialized = false
    private let onboardingController = OnboardingWindowController()
    private let lazyUpdater = LazyUpdaterController()

    var body: some Scene {
        MenuBarExtra {
            if !onboardingCompleted {
                Button("Show Setup Window") {
                    onboardingController.bringToFront()
                }
                Divider()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            } else {
                MenuBarView(appState: appState, updaterController: lazyUpdater.controller)
            }
        } label: {
            let isRecording = appState.activeMeetingSession != nil
                || appState.status == .recording
                || appState.status == .transcribing
                || appState.status == .cleaningUp

            Group {
                if isRecording {
                    // Glyph + red dot (composited NSImage so the dot is
                    // actually red in the menu bar).
                    Image(nsImage: MenuBarIconRenderer.recordingBadgedIcon())
                        .renderingMode(.original)
                } else {
                    switch appState.status {
                    case .loading:
                        Image(systemName: "ellipsis.circle")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.orange)
                    case .error:
                        Image(systemName: "exclamationmark.triangle")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.yellow)
                    default:
                        Image("MenuBarIcon")
                            .renderingMode(.template)
                    }
                }
            }
            .onAppear {
                ProcessInfo.processInfo.disableAutomaticTermination(Self.automaticTerminationReason)
                guard !hasInitialized else { return }
                hasInitialized = true
                if onboardingCompleted {
                    Task { await appState.initialize() }
                } else {
                    onboardingController.show(appState: appState) {
                        onboardingCompleted = true
                        Task { await appState.initialize() }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                ProcessInfo.processInfo.enableAutomaticTermination(Self.automaticTerminationReason)
                appState.prepareForTermination()
            }
        }
    }
}
