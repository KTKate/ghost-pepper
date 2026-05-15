import AppKit
import CoreAudio
import Foundation

/// Result of querying `pmset -g assertions` for Microsoft Teams call state.
enum TeamsCallAssertionState {
    /// pmset ran cleanly and reported a Teams "Call in progress" assertion.
    case callActive
    /// pmset ran cleanly and reported no Teams call assertion.
    case noCall
    /// pmset could not be launched, exited non-zero, or its output could
    /// not be decoded. Callers decide their own fail-safe direction.
    case unreadable
}

/// Shared, race-free query of the Teams "Call in progress" power assertion.
///
/// `pmset -g assertions` emits a few KB of ASCII — well under the 64 KB pipe
/// buffer — so reading to EOF *before* `waitUntilExit()` is correct: the write
/// end closes when pmset exits, so the read returns the complete output without
/// the pipe-buffer deadlock or the truncation race the old chunked reader hit.
enum TeamsCallAssertion {
    static func query() -> (state: TeamsCallAssertionState, teamsLines: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()  // discard stderr

        do {
            try process.run()
        } catch {
            return (.unreadable, "")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else {
            return (.unreadable, "")
        }

        let teamsLines = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0.lowercased().contains("teams") || $0.lowercased().contains("microsoft") }
            .joined(separator: " | ")

        let state: TeamsCallAssertionState = output.contains("Microsoft Teams Call in progress")
            ? .callActive
            : .noCall
        return (state, teamsLines)
    }
}

/// Detected meeting app info.
struct DetectedMeeting {
    let appName: String
    let bundleIdentifier: String
    let suggestedName: String // e.g. "Zoom — 10:03 AM"
    var isVideo: Bool = false
    var sourceURL: String? = nil
}

/// Monitors for running meeting/video call apps and notifies when one is detected.
/// Off by default — must be explicitly enabled via Settings.
@MainActor
final class MeetingDetector {
    var onMeetingDetected: ((DetectedMeeting) -> Void)?
    var debugLogger: ((DebugLogCategory, String) -> Void)?

    private var pollTimer: Timer?
    private var isRunning = false

    /// Last frontmost bundle ID we logged. Used to suppress per-tick spam
    /// when the frontmost app hasn't changed.
    private var lastLoggedFrontmostBundleID: String?
    private var pollCount = 0

    /// Bundle IDs that have been detected and dismissed this session (don't re-prompt).
    private var dismissedBundleIDs: Set<String> = []
    
    /// Track whether Teams power assertion was present in the last poll.
    /// Used to detect transitions from no-call to active-call.
    private var teamsAssertionWasPresentLastPoll = false

    /// Bundle IDs of known meeting/video call apps.
    private static let knownMeetingApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "us.zoom.videomeeting": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams": "Microsoft Teams",
        "com.apple.FaceTime": "FaceTime",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.cisco.webex.meetings": "Webex",
        "com.google.hangouts": "Google Meet",
        "com.slack.Slack": "Slack",
        "discord": "Discord",
        "com.hnc.Discord": "Discord",
    ]

    /// Window title patterns that suggest a browser-based meeting is active.
    private static let browserMeetingPatterns: [String] = [
        "meet.google.com",
        "google meet",
        "meet -",
        "zoom.us/j/",
        "zoom.us/wc/",
        "teams.microsoft.com",
        "teams.live.com",
        "whereby.com",
    ]

    /// Video site detection rules. `titlePattern` is checked against browser window titles.
    /// `playing` prefix (e.g. "▶") is optional — when present, only matches actively playing videos.
    private struct VideoSiteRule {
        let urlPattern: String
        let siteName: String
        let playingPrefix: String? // e.g. "▶" for YouTube
    }

    private static let videoSiteRules: [VideoSiteRule] = [
        VideoSiteRule(urlPattern: "- youtube", siteName: "YouTube", playingPrefix: nil),
        VideoSiteRule(urlPattern: "youtube.com", siteName: "YouTube", playingPrefix: nil),
        VideoSiteRule(urlPattern: "loom.com", siteName: "Loom", playingPrefix: nil),
        VideoSiteRule(urlPattern: "- vimeo", siteName: "Vimeo", playingPrefix: nil),
        VideoSiteRule(urlPattern: "vimeo.com", siteName: "Vimeo", playingPrefix: nil),
        VideoSiteRule(urlPattern: "twitch.tv", siteName: "Twitch", playingPrefix: nil),
        VideoSiteRule(urlPattern: "- twitch", siteName: "Twitch", playingPrefix: nil),
        VideoSiteRule(urlPattern: "netflix.com", siteName: "Netflix", playingPrefix: nil),
        VideoSiteRule(urlPattern: "dailymotion.com", siteName: "Dailymotion", playingPrefix: nil),
    ]

    /// Bundle IDs of common browsers.
    private static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser", // Arc
        "com.brave.Browser",
        "com.operasoftware.Opera",
    ]

    /// Start polling for meeting apps.
    func start() {
        guard !isRunning else {
            debugLogger?(.model, "MeetingDetector: start() called but already running.")
            return
        }
        isRunning = true
        pollCount = 0
        lastLoggedFrontmostBundleID = nil

        debugLogger?(.model, "MeetingDetector: starting — polling every 5s for known meeting apps and Teams power assertion.")

        // Poll every 5 seconds — cheap operation.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkForMeetingApps()
            }
        }

        // Also check immediately.
        checkForMeetingApps()
    }

    /// Stop polling.
    func stop() {
        if isRunning {
            debugLogger?(.model, "MeetingDetector: stopping after \(pollCount) poll(s).")
        }
        isRunning = false
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Mark a meeting app as dismissed so we don't prompt again this session.
    func dismiss(bundleID: String) {
        dismissedBundleIDs.insert(bundleID)
    }

    /// Reset dismissed state (e.g. when the user re-enables detection).
    func resetDismissals() {
        dismissedBundleIDs.removeAll()
        teamsAssertionWasPresentLastPoll = false
    }

    /// Track the last diagnostic key (state + Teams lines) we logged so we
    /// only emit a debug entry when it changes — prevents per-poll spam.
    private var lastLoggedTeamsAssertionLines: String?

    // MARK: - Private

    /// Returns true only when Teams cleanly holds a "Call in progress" power
    /// assertion. For the *start* path the fail-safe is "not active": a
    /// transient pmset hiccup must never spuriously begin a recording. The
    /// next 5s poll retries, so a real call is still picked up promptly.
    private func isTeamsCallActive() -> Bool {
        let result = TeamsCallAssertion.query()

        // Diagnostic: log the Teams/Microsoft assertion lines (and the state)
        // when they change, so we can see exactly what Teams is registering.
        let diagnosticKey = "\(result.state)|\(result.teamsLines)"
        if diagnosticKey != lastLoggedTeamsAssertionLines {
            lastLoggedTeamsAssertionLines = diagnosticKey
            switch result.state {
            case .unreadable:
                debugLogger?(.model, "MeetingDetector: pmset unreadable — treating as no Teams call this poll.")
            case .noCall where result.teamsLines.isEmpty:
                debugLogger?(.model, "MeetingDetector: pmset reports no Teams/Microsoft assertion lines right now.")
            case .noCall, .callActive:
                debugLogger?(.model, "MeetingDetector: pmset Teams/Microsoft lines → \(result.teamsLines)")
            }
        }

        return result.state == .callActive
    }

    private func checkForMeetingApps() {
        pollCount += 1

        // Check Teams power assertion first — most reliable for Teams 2.0.
        // Only fire on transition from no-assertion to assertion-present.
        let teamsAssertionPresent = isTeamsCallActive()

        // Clear dismissal when call ends so we can detect the next call
        if !teamsAssertionPresent && teamsAssertionWasPresentLastPoll {
            let teamsKey = "teams-assertion"
            dismissedBundleIDs.remove(teamsKey)
            debugLogger?(.model, "MeetingDetector: Teams power assertion released; cleared dismissal so a new call can be detected.")
        }

        if teamsAssertionPresent && !teamsAssertionWasPresentLastPoll {
            // Transition detected: Teams call just started.
            let teamsKey = "teams-assertion"
            if !dismissedBundleIDs.contains(teamsKey) {
                debugLogger?(.model, "MeetingDetector: Teams power assertion appeared — firing Microsoft Teams meeting.")
                let teamsApp = NSWorkspace.shared.runningApplications.first {
                    $0.bundleIdentifier == "com.microsoft.teams2" || $0.bundleIdentifier == "com.microsoft.teams"
                }
                let titles = teamsApp.map { AccessibilityWindowTitles.all(for: $0) } ?? []
                let suggestedName = MeetingWindowHeuristics.bestMeetingTitle(in: titles, appName: "Microsoft Teams")
                    ?? Self.suggestedMeetingName(appName: "Microsoft Teams")

                let meeting = DetectedMeeting(
                    appName: "Microsoft Teams",
                    bundleIdentifier: "com.microsoft.teams2",
                    suggestedName: suggestedName
                )
                onMeetingDetected?(meeting)
                // Dismiss AFTER callback so it can handle the detection
                dismiss(bundleID: teamsKey)
            } else {
                debugLogger?(.model, "MeetingDetector: Teams power assertion appeared but key 'teams-assertion' is already dismissed this session; not firing.")
            }
        }
        teamsAssertionWasPresentLastPoll = teamsAssertionPresent

        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              let frontmostBundleID = frontmost.bundleIdentifier else {
            if lastLoggedFrontmostBundleID != "<none>" {
                debugLogger?(.model, "MeetingDetector: poll #\(pollCount) — no frontmost application detected.")
                lastLoggedFrontmostBundleID = "<none>"
            }
            return
        }

        // Log frontmost app on first poll and whenever it changes.
        if frontmostBundleID != lastLoggedFrontmostBundleID {
            let appName = frontmost.localizedName ?? "?"
            let known = Self.knownMeetingApps[frontmostBundleID] != nil
            let isBrowser = Self.browserBundleIDs.contains(frontmostBundleID)
            debugLogger?(.model, "MeetingDetector: poll #\(pollCount) — frontmost=\(appName) [\(frontmostBundleID)] knownMeetingApp=\(known) isBrowser=\(isBrowser) teamsAssertion=\(teamsAssertionPresent)")
            lastLoggedFrontmostBundleID = frontmostBundleID
        }

        // Check known meeting apps — only when frontmost to avoid false positives
        // from Zoom/Teams running in the background.
        // Skip Teams here since we use power assertion detection above (more reliable).
        if let appName = Self.knownMeetingApps[frontmostBundleID] {
            if appName == "Microsoft Teams" {
                // Detected via power assertion above; nothing to do here.
                return
            }

            if dismissedBundleIDs.contains(frontmostBundleID) {
                debugLogger?(.model, "MeetingDetector: \(appName) is frontmost but bundle '\(frontmostBundleID)' is already dismissed this session; not firing.")
                return
            }

            debugLogger?(.model, "MeetingDetector: \(appName) [\(frontmostBundleID)] became frontmost — firing detection.")
            dismiss(bundleID: frontmostBundleID)
            let titles = AccessibilityWindowTitles.all(for: frontmost)
            let suggestedName = MeetingWindowHeuristics.bestMeetingTitle(in: titles, appName: appName)
                ?? Self.suggestedMeetingName(appName: appName)
            let meeting = DetectedMeeting(
                appName: appName,
                bundleIdentifier: frontmostBundleID,
                suggestedName: suggestedName
            )
            onMeetingDetected?(meeting)
            return
        }

        // Check browsers for meeting URLs or video sites.
        if Self.browserBundleIDs.contains(frontmostBundleID) {
            let bundleID = frontmostBundleID
            let titles = AccessibilityWindowTitles.all(for: frontmost)

            // Check meetings first.
            if let meetingName = matchMeetingPattern(in: titles) {
                if dismissedBundleIDs.contains("browser-meeting") {
                    debugLogger?(.model, "MeetingDetector: browser meeting '\(meetingName)' matched but 'browser-meeting' is already dismissed this session; not firing.")
                } else {
                    debugLogger?(.model, "MeetingDetector: browser meeting matched: \(meetingName) — firing.")
                    dismiss(bundleID: "browser-meeting")
                    let meeting = DetectedMeeting(
                        appName: meetingName,
                        bundleIdentifier: bundleID,
                        suggestedName: Self.suggestedMeetingName(appName: meetingName)
                    )
                    onMeetingDetected?(meeting)
                    return
                }
            }

            // Check video sites.
            if let (siteName, videoTitle) = matchVideoSite(in: titles) {
                let dismissKey = "video-\(siteName)"
                if dismissedBundleIDs.contains(dismissKey) {
                    debugLogger?(.model, "MeetingDetector: video site \(siteName) matched but '\(dismissKey)' is already dismissed this session; not firing.")
                    return
                }
                debugLogger?(.model, "MeetingDetector: video site \(siteName) matched — firing.")
                dismiss(bundleID: dismissKey)

                let suggestedName: String
                if let videoTitle = videoTitle {
                    suggestedName = "\(siteName) — \(videoTitle)"
                } else {
                    suggestedName = Self.suggestedMeetingName(appName: siteName)
                }
                let url = browserURL(app: frontmost)
                let meeting = DetectedMeeting(
                    appName: siteName,
                    bundleIdentifier: bundleID,
                    suggestedName: suggestedName,
                    isVideo: true,
                    sourceURL: url
                )
                onMeetingDetected?(meeting)
            }
        }
    }

    /// Get all window titles from a browser app.
    /// Read the URL from the browser's address bar via Accessibility API.
    private func browserURL(app: NSRunningApplication) -> String? {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        // Get the focused window
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success else {
            return nil
        }
        let window = windowValue as! AXUIElement

        // Search for a text field with role AXTextField that contains a URL-like value
        func findURLField(in element: AXUIElement) -> String? {
            var roleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
               let role = roleValue as? String, role == "AXTextField" {
                var valueRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
                   let value = valueRef as? String,
                   value.contains(".com") || value.contains("http") || value.contains(".") {
                    return value
                }
            }

            var childrenValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
                  let children = childrenValue as? [AXUIElement] else {
                return nil
            }
            for child in children.prefix(20) { // limit depth
                if let url = findURLField(in: child) { return url }
            }
            return nil
        }

        return findURLField(in: window)
    }

    /// Check if any window title matches a browser-based meeting.
    private func matchMeetingPattern(in titles: [String]) -> String? {
        for title in titles {
            let lowered = title.lowercased()
            for pattern in Self.browserMeetingPatterns {
                if lowered.contains(pattern) {
                    if lowered.contains("meet.google.com") || lowered.contains("google meet") || lowered.hasPrefix("meet -") { return "Google Meet" }
                    if lowered.contains("zoom.us") { return "Zoom" }
                    if lowered.contains("teams.microsoft.com") || lowered.contains("teams.live.com") { return "Microsoft Teams" }
                    if lowered.contains("whereby.com") { return "Whereby" }
                    return "Video Call"
                }
            }
        }
        return nil
    }

    /// Check if any window title matches a video site. Returns (siteName, videoTitle?).
    /// For sites with a `playingPrefix` (e.g. YouTube's "▶"), only matches when the prefix is present.
    private func matchVideoSite(in titles: [String]) -> (String, String?)? {
        for title in titles {
            let lowered = title.lowercased()
            for rule in Self.videoSiteRules {
                guard lowered.contains(rule.urlPattern) || title.contains(rule.urlPattern) else {
                    continue
                }

                // If rule has a playing prefix, only match when video is actively playing.
                if let prefix = rule.playingPrefix {
                    guard title.hasPrefix(prefix) else { continue }
                    // Extract video title: "▶ How to Cook Pasta - YouTube" → "How to Cook Pasta"
                    let stripped = String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                    let videoTitle = stripped
                        .replacingOccurrences(of: " - YouTube", with: "")
                        .replacingOccurrences(of: " - Vimeo", with: "")
                        .replacingOccurrences(of: " on Vimeo", with: "")
                        .replacingOccurrences(of: " - Dailymotion", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    return (rule.siteName, videoTitle.isEmpty ? nil : videoTitle)
                }

                // No prefix required — site URL in title is enough.
                // Try to extract a video title by removing the site name suffix.
                let videoTitle = title
                    .replacingOccurrences(of: " | Loom", with: "")
                    .replacingOccurrences(of: " - Loom", with: "")
                    .replacingOccurrences(of: " - Twitch", with: "")
                    .replacingOccurrences(of: " - Netflix", with: "")
                    .trimmingCharacters(in: .whitespaces)
                return (rule.siteName, videoTitle == title ? nil : videoTitle)
            }
        }
        return nil
    }

    /// Generate a default meeting name like "Zoom — 10:03 AM".
    private static func suggestedMeetingName(appName: String) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return "\(appName) — \(formatter.string(from: Date()))"
    }
}
