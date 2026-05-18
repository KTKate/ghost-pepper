import AppKit
import CoreAudio
import Foundation

/// Result of querying `pmset -g assertions` for Microsoft Teams call state.
enum TeamsCallAssertionState {
    /// pmset output contained the Teams "Call in progress" assertion.
    case callActive
    /// pmset output was read and decoded, but no Teams call assertion.
    case noCall
    /// pmset could not be launched, or produced no output at all.
    case unreadable
}

/// Shared, race-free query of the Teams "Call in progress" power assertion.
///
/// `pmset -g assertions` emits a few KB of ASCII — well under the 64 KB pipe
/// buffer — so reading to EOF *before* `waitUntilExit()` is correct: the write
/// end closes when pmset exits, so the read returns the complete output without
/// the pipe-buffer deadlock or the truncation race the old chunked reader hit.
///
/// Deliberately does NOT gate on `terminationStatus`: pmset can exit non-zero
/// while still printing valid assertion output, and the original working
/// implementation never checked it. Gating on it was a regression that made
/// every read look `.unreadable`.
enum TeamsCallAssertion {
    /// - Returns: the parsed state plus a diagnostic string — the Teams/
    ///   Microsoft assertion lines for `callActive`/`noCall`, or the failure
    ///   reason for `unreadable`.
    static func query() -> (state: TeamsCallAssertionState, diagnostic: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]

        let outPipe = Pipe()
        process.standardOutput = outPipe
        // Discard stderr to /dev/null — an unread Pipe() could fill its 64 KB
        // buffer and stall pmset.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return (.unreadable, "launch failed: \(error.localizedDescription)")
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard !data.isEmpty else {
            return (.unreadable, "empty output (exit \(process.terminationStatus))")
        }
        // pmset lists every process holding a power assertion system-wide, so
        // an unrelated process's name can carry non-UTF8 bytes. Strict UTF-8
        // decoding returns nil on a single bad byte anywhere in the buffer,
        // which marked every read .unreadable and (on the stop path) pinned
        // recordings on forever. We only scan for the ASCII marker
        // "Microsoft Teams Call in progress", so repair invalid sequences
        // (→ U+FFFD) instead of failing the whole read.
        let output = String(decoding: data, as: UTF8.self)

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

/// Frontmost-independent "is audio flowing" probe.
///
/// Uses CoreAudio's `kAudioDevicePropertyDeviceIsRunningSomewhere`, which is
/// true whenever *any* process is actively using the default input or output
/// device. A call lights up the mic (you're talking) and the speakers (you
/// hear others) regardless of which window is on top — so this is a reliable
/// "you're in a meeting" signal that never looks at the frontmost app.
enum AudioActivityProbe {
    static func isActive() -> Bool {
        deviceRunning(defaultSelector: kAudioHardwarePropertyDefaultInputDevice)
            || deviceRunning(defaultSelector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    private static func deviceRunning(defaultSelector: AudioObjectPropertySelector) -> Bool {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: defaultSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defaultAddr, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else {
            return false
        }

        var running: UInt32 = 0
        var runSize = UInt32(MemoryLayout<UInt32>.size)
        var runAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            deviceID, &runAddr, 0, nil, &runSize, &running
        ) == noErr else {
            return false
        }
        return running != 0
    }
}

/// Monitors for running meeting/video call apps and notifies when one is detected.
/// Off by default — must be explicitly enabled via Settings.
@MainActor
final class MeetingDetector {
    var onMeetingDetected: ((DetectedMeeting) -> Void)?
    var debugLogger: ((DebugLogCategory, String) -> Void)?

    /// Returns true when Ghost Pepper itself is the reason audio is active
    /// (hotkey dictation or an in-progress meeting recording), so mic/speaker
    /// activity caused by the app is not mistaken for a new meeting.
    var selfAudioActive: (() -> Bool)?

    private var pollTimer: Timer?
    private var isRunning = false

    private var pollCount = 0
    private var audioWasActiveLastPoll = false
    private var lastHeartbeatKey: String?

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
        lastHeartbeatKey = nil
        audioWasActiveLastPoll = false

        debugLogger?(.model, "MeetingDetector: starting — polling every 5s (process list + audio activity + pmset; frontmost-independent).")

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

    /// Last pmset state we logged, and a counter for the ~1-minute heartbeat.
    /// We log on every state change AND periodically, so a *recurring* failure
    /// (e.g. pmset persistently unreadable) stays visible instead of being
    /// deduped to a single startup line.
    private var lastLoggedPmsetState: String?
    private var pmsetLogHeartbeat = 0

    // MARK: - Private

    /// Returns true only when pmset reports the Teams "Call in progress"
    /// assertion. For the *start* path the fail-safe is "not active": a
    /// transient pmset hiccup must never spuriously begin a recording. The
    /// next 5s poll retries, so a real call is still picked up promptly.
    private func isTeamsCallActive() -> Bool {
        let result = TeamsCallAssertion.query()

        pmsetLogHeartbeat += 1
        let stateKey: String
        switch result.state {
        case .callActive: stateKey = "callActive"
        case .noCall: stateKey = "noCall"
        case .unreadable: stateKey = "unreadable"
        }
        // ~once per minute at the 5s poll interval, plus on any change.
        let heartbeat = pmsetLogHeartbeat % 12 == 0
        if stateKey != lastLoggedPmsetState || heartbeat {
            lastLoggedPmsetState = stateKey
            switch result.state {
            case .callActive:
                debugLogger?(.model, "MeetingDetector: pmset → Teams CALL ACTIVE [\(result.diagnostic)]")
            case .noCall where result.diagnostic.isEmpty:
                debugLogger?(.model, "MeetingDetector: pmset → readable, no Teams/Microsoft assertion present.")
            case .noCall:
                debugLogger?(.model, "MeetingDetector: pmset → Teams/Microsoft lines but no active call: \(result.diagnostic)")
            case .unreadable:
                debugLogger?(.model, "MeetingDetector: pmset UNREADABLE — \(result.diagnostic) — treating as no call this poll.")
            }
        }

        return result.state == .callActive
    }

    /// Detection is intentionally frontmost-independent. It never looks at
    /// which window is on top — meeting windows are usually in the background.
    /// Signals, in priority order:
    ///   1. Teams "Call in progress" power assertion (pmset) — instant, zero
    ///      false positives, but Teams only registers it transiently.
    ///   2. A known meeting app is *running* (process list) AND audio is
    ///      flowing (mic/speaker active) AND it isn't Ghost Pepper's own
    ///      recording — robust even when pmset misses the call.
    ///   3. A browser is *running* with a meeting/video tab AND audio is
    ///      flowing — windows read via Accessibility, not "frontmost".
    private func checkForMeetingApps() {
        pollCount += 1

        // ---- Signal 1: Teams power assertion (fast path) ----
        let teamsAssertionPresent = isTeamsCallActive()
        if !teamsAssertionPresent && teamsAssertionWasPresentLastPoll {
            dismissedBundleIDs.remove("teams-assertion")
            debugLogger?(.model, "MeetingDetector: Teams power assertion released; cleared dismissal.")
        }
        if teamsAssertionPresent && !teamsAssertionWasPresentLastPoll {
            if dismissedBundleIDs.contains("teams-assertion") {
                debugLogger?(.model, "MeetingDetector: Teams assertion appeared but already dismissed this session; not firing.")
            } else {
                debugLogger?(.model, "MeetingDetector: Teams power assertion appeared — firing Microsoft Teams meeting.")
                fireMeeting(appName: "Microsoft Teams", bundleID: "com.microsoft.teams2", dismissKey: "teams-assertion")
            }
        }
        teamsAssertionWasPresentLastPoll = teamsAssertionPresent

        // ---- Audio-driven, frontmost-independent detection ----
        let audioActive = AudioActivityProbe.isActive()
        let selfActive = selfAudioActive?() ?? false

        // When audio stops, clear audio-based dismissals so the next call
        // re-detects (mirrors the pmset-release logic above).
        if !audioActive && audioWasActiveLastPoll {
            let cleared = dismissedBundleIDs.filter { $0.hasPrefix("audio:") }
            if !cleared.isEmpty {
                dismissedBundleIDs.subtract(cleared)
                debugLogger?(.model, "MeetingDetector: audio went idle; cleared audio-based dismissals so the next call re-detects.")
            }
        }
        audioWasActiveLastPoll = audioActive

        // Signal heartbeat — reports the signals actually used (NOT what is
        // on top). Logged on change and ~once per minute.
        let heartbeatKey = "\(audioActive)|\(selfActive)|\(teamsAssertionPresent)"
        if heartbeatKey != lastHeartbeatKey || pollCount % 12 == 0 {
            lastHeartbeatKey = heartbeatKey
            debugLogger?(.model, "MeetingDetector: poll #\(pollCount) — audioActive=\(audioActive) selfRecording=\(selfActive) pmsetTeamsCall=\(teamsAssertionPresent)")
        }

        guard audioActive else { return }
        guard !selfActive else {
            // Ghost Pepper's own dictation/recording is the audio source.
            return
        }

        let running = NSWorkspace.shared.runningApplications

        // ---- Signal 2: a known meeting app is running + audio active ----
        for app in running {
            guard let bundleID = app.bundleIdentifier,
                  let appName = Self.knownMeetingApps[bundleID] else { continue }
            let dismissKey = "audio:\(bundleID)"
            if dismissedBundleIDs.contains(dismissKey) { continue }
            debugLogger?(.model, "MeetingDetector: \(appName) is running and audio is active — firing (frontmost-independent).")
            fireMeeting(appName: appName, bundleID: bundleID, dismissKey: dismissKey, app: app)
            return
        }

        // ---- Signal 3: a running browser has a meeting/video tab ----
        for app in running {
            guard let bundleID = app.bundleIdentifier,
                  Self.browserBundleIDs.contains(bundleID) else { continue }
            let titles = AccessibilityWindowTitles.all(for: app)

            if let meetingName = matchMeetingPattern(in: titles) {
                let key = "audio:browser-meeting"
                if dismissedBundleIDs.contains(key) { continue }
                debugLogger?(.model, "MeetingDetector: browser meeting '\(meetingName)' + audio active — firing.")
                dismiss(bundleID: key)
                onMeetingDetected?(DetectedMeeting(
                    appName: meetingName,
                    bundleIdentifier: bundleID,
                    suggestedName: Self.suggestedMeetingName(appName: meetingName)
                ))
                return
            }

            if let (siteName, videoTitle) = matchVideoSite(in: titles) {
                let key = "audio:video-\(siteName)"
                if dismissedBundleIDs.contains(key) { continue }
                debugLogger?(.model, "MeetingDetector: video site \(siteName) + audio active — firing.")
                dismiss(bundleID: key)
                let suggestedName = videoTitle.map { "\(siteName) — \($0)" }
                    ?? Self.suggestedMeetingName(appName: siteName)
                onMeetingDetected?(DetectedMeeting(
                    appName: siteName,
                    bundleIdentifier: bundleID,
                    suggestedName: suggestedName,
                    isVideo: true,
                    sourceURL: browserURL(app: app)
                ))
                return
            }
        }
    }

    /// Fire a detected meeting for a known native app, pulling the meeting
    /// title from that app's windows via Accessibility (works on a background
    /// app — it does not need to be frontmost).
    private func fireMeeting(
        appName: String,
        bundleID: String,
        dismissKey: String,
        app: NSRunningApplication? = nil
    ) {
        let resolvedApp = app ?? NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleID
                || (appName == "Microsoft Teams" && $0.bundleIdentifier == "com.microsoft.teams")
        }
        let titles = resolvedApp.map { AccessibilityWindowTitles.all(for: $0) } ?? []
        let suggestedName = MeetingWindowHeuristics.bestMeetingTitle(in: titles, appName: appName)
            ?? Self.suggestedMeetingName(appName: appName)
        onMeetingDetected?(DetectedMeeting(
            appName: appName,
            bundleIdentifier: bundleID,
            suggestedName: suggestedName
        ))
        dismiss(bundleID: dismissKey)
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
