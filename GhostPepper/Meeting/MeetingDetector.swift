import AppKit
import CoreAudio
import Foundation

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

    private var pollTimer: Timer?
    private var isRunning = false

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
        guard !isRunning else { return }
        isRunning = true

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

    // MARK: - Private
    
    /// Returns true if Microsoft Teams currently holds a "Call in progress"
    /// power assertion. This is the most reliable signal for Teams 2.0 call
    /// state on macOS — Teams registers the assertion when a call starts and
    /// releases it when the call ends.
    private func isTeamsCallActive() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()  // discard stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }

        guard let data = try? pipe.fileHandleForReading.readToEnd(),
              let output = String(data: data, encoding: .utf8) else {
            return false
        }

        return output.contains("Microsoft Teams Call in progress")
    }

    private func checkForMeetingApps() {
        // Check Teams power assertion first — most reliable for Teams 2.0.
        // Only fire on transition from no-assertion to assertion-present.
        let teamsAssertionPresent = isTeamsCallActive()
        
        // Clear dismissal when call ends so we can detect the next call
        if !teamsAssertionPresent && teamsAssertionWasPresentLastPoll {
            let teamsKey = "teams-assertion"
            dismissedBundleIDs.remove(teamsKey)
        }
        
        if teamsAssertionPresent && !teamsAssertionWasPresentLastPoll {
            // Transition detected: Teams call just started.
            let teamsKey = "teams-assertion"
            if !dismissedBundleIDs.contains(teamsKey) {
                // Try to get the actual meeting title from Teams windows
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
            }
        }
        teamsAssertionWasPresentLastPoll = teamsAssertionPresent
        
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              let frontmostBundleID = frontmost.bundleIdentifier else { return }

        // Check known meeting apps — only when frontmost to avoid false positives
        // from Zoom/Teams running in the background.
        // Skip Teams here since we use power assertion detection above (more reliable).
        if let appName = Self.knownMeetingApps[frontmostBundleID],
           !dismissedBundleIDs.contains(frontmostBundleID) {
            
            // Skip Teams - we detect it via power assertion above
            if appName == "Microsoft Teams" {
                return
            }
            
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
            if !dismissedBundleIDs.contains("browser-meeting"),
               let meetingName = matchMeetingPattern(in: titles) {
                dismiss(bundleID: "browser-meeting")
                let meeting = DetectedMeeting(
                    appName: meetingName,
                    bundleIdentifier: bundleID,
                    suggestedName: Self.suggestedMeetingName(appName: meetingName)
                )
                onMeetingDetected?(meeting)
                return
            }

            // Check video sites.
            if let (siteName, videoTitle) = matchVideoSite(in: titles) {
                let dismissKey = "video-\(siteName)"
                guard !dismissedBundleIDs.contains(dismissKey) else { return }
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
