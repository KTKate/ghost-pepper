import AppKit
import Foundation

/// Orchestrates a single meeting transcription session.
/// Owns DualStreamCapture + ChunkedTranscriptionPipeline + MeetingTranscript.
@MainActor
final class MeetingSession: ObservableObject {
    @Published var isActive = false
    @Published var fileURL: URL?
    @Published var noAudioDetected = false

    @Published var transcript: MeetingTranscript

    var onAutoStopRequested: ((MeetingSession) -> Void)?

    private let capture = DualStreamCapture()
    private var pipeline: ChunkedTranscriptionPipeline?
    private let transcriber: SpeechTranscriber
    private let saveDirectory: URL

    /// URLs of chunk WAV files the pipeline wrote to disk during the meeting.
    /// The pipeline's onChunkSaved callback runs off the main actor, so this
    /// list is guarded by an explicit lock and marked nonisolated.
    nonisolated(unsafe) private var savedChunkURLs: [SavedChunk] = []
    nonisolated private let chunkURLLock = NSLock()

    struct SavedChunk: Sendable {
        let index: Int
        let source: AudioStreamSource
        let url: URL
    }
    private let detectedMeetingAppName: String?
    private let detectedMeetingBundleIdentifier: String?

    /// How often to auto-save the markdown file (matches chunk interval).
    private var autoSaveTimer: Timer?
    private var silenceCheckTimer: Timer?
    private var meetingEndCheckTimer: Timer?
    private var hasReceivedAudio = false
    private var hasAutoUpdatedTitle = false
    private let originalName: String
    private let ocrService: FrontmostWindowOCRService
    private var inactiveMeetingPollCount = 0
    private let echoCancellationConfig: EchoCancellationEngine.Configuration

    init(
        meetingName: String,
        detectedMeeting: DetectedMeeting? = nil,
        transcriber: SpeechTranscriber,
        saveDirectory: URL,
        ocrService: FrontmostWindowOCRService = FrontmostWindowOCRService(),
        echoCancellationEnabled: Bool = true,
        echoCancellationSensitivity: Double = 0.7
    ) {
        self.transcript = MeetingTranscript(meetingName: meetingName)
        self.transcriber = transcriber
        self.saveDirectory = saveDirectory
        self.originalName = meetingName
        self.ocrService = ocrService
        self.detectedMeetingAppName = detectedMeeting?.appName
        self.detectedMeetingBundleIdentifier = detectedMeeting?.bundleIdentifier
        
        // Configure echo cancellation based on user settings
        var config = EchoCancellationEngine.Configuration.default
        config.enabled = echoCancellationEnabled
        config.audioCorrelationThreshold = echoCancellationSensitivity
        config.textSimilarityThreshold = max(0.7, echoCancellationSensitivity - 0.1)
        self.echoCancellationConfig = config
    }

    /// Start dual-stream capture and chunked transcription.
    func start() async throws {
        guard !isActive else { return }

        let chunkDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhostPepper")
            .appendingPathComponent("meeting-\(transcript.sessionID.uuidString)")
            .appendingPathComponent("chunks")

        let newPipeline = ChunkedTranscriptionPipeline(
            transcriber: transcriber,
            chunkDirectory: chunkDir,
            echoCancellationConfig: echoCancellationConfig
        )

        newPipeline.onSegmentTranscribed = { [weak self] result in
            guard let self = self else { return }
            
            // Skip echo-suppressed segments (audio loopback from speakers to mic)
            if result.isEchoSuppressed {
                print("MeetingSession: Suppressed echo segment (confidence: \(String(format: "%.2f", result.echoConfidence))): \(result.text.prefix(50))...")
                return
            }
            
            let speaker: SpeakerLabel = result.source == .mic ? .me : .remote(name: nil)
            let segment = TranscriptSegment(
                id: UUID(),
                speaker: speaker,
                startTime: result.startTime,
                endTime: result.endTime,
                text: result.text
            )
            self.transcript.appendSegment(segment)
            self.autoSave()
        }

        newPipeline.onChunkSaved = { [weak self] url, source in
            guard let self = self else { return }
            let index = MeetingSession.parseChunkIndex(from: url) ?? -1
            self.chunkURLLock.lock()
            self.savedChunkURLs.append(SavedChunk(index: index, source: source, url: url))
            self.chunkURLLock.unlock()
        }

        capture.onAudioChunk = { [weak self, weak newPipeline] chunk in
            newPipeline?.appendAudio(chunk)
            if let self = self, !self.hasReceivedAudio {
                // Check if chunk has actual audio (not silence)
                let rms = sqrt(chunk.samples.map { $0 * $0 }.reduce(0, +) / max(Float(chunk.samples.count), 1))
                if rms > 0.001 {
                    Task { @MainActor in
                        self.hasReceivedAudio = true
                        self.noAudioDetected = false
                        self.silenceCheckTimer?.invalidate()
                    }
                }
            }
        }

        pipeline = newPipeline

        try await capture.start()
        newPipeline.start()
        isActive = true

        // Initial save creates the file immediately.
        autoSave()

        // Check for silence after 10 seconds — if no audio detected, warn the user.
        silenceCheckTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isActive, !self.hasReceivedAudio else { return }
                self.noAudioDetected = true
                print("MeetingSession: no audio detected after 10 seconds")
            }
        }

        // Check Google Calendar for current meeting (if connected)
        Task {
            await populateFromCalendar()
        }

        // Try to auto-update title and grab attendees multiple times over the first minute.
        // People join at different times, so retrying gives us better coverage.
        for delay in [3.0, 15.0, 30.0, 60.0] {
            Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self = self, self.isActive else { return }
                    self.autoUpdateTitleFromDetectedMeetingApp()
                    await self.captureAttendees()
                }
            }
        }

        startMeetingEndMonitorIfNeeded()

        print("MeetingSession: started '\(transcript.meetingName)'")
    }

    /// Stop capture, process remaining audio, finalize transcript.
    func stop() async {
        guard isActive else { return }
        isActive = false

        pipeline?.stop()
        _ = await capture.stop()

        transcript.endDate = Date()

        // Final save with end date.
        autoSave()

        autoSaveTimer?.invalidate()
        autoSaveTimer = nil
        silenceCheckTimer?.invalidate()
        silenceCheckTimer = nil
        meetingEndCheckTimer?.invalidate()
        meetingEndCheckTimer = nil
        inactiveMeetingPollCount = 0

        print("MeetingSession: stopped '\(transcript.meetingName)' — \(transcript.segments.count) segments, \(transcript.formattedDuration)")
    }

    /// Snapshot of chunk URLs collected during the meeting, sorted by chunk
    /// index (ascending). Each chunk index may have a mic file, a system file,
    /// both, or (rarely) neither.
    func collectedChunks() -> [SavedChunk] {
        chunkURLLock.lock()
        defer { chunkURLLock.unlock() }
        return savedChunkURLs.sorted { lhs, rhs in
            if lhs.index != rhs.index { return lhs.index < rhs.index }
            // Stable ordering within a chunk index: system before mic.
            return lhs.source.sortKey < rhs.source.sortKey
        }
    }

    /// Parse the index from a chunk filename of the form `chunk-<index>-<source>.wav`.
    nonisolated static func parseChunkIndex(from url: URL) -> Int? {
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.split(separator: "-")
        guard parts.count >= 3, parts[0] == "chunk", let index = Int(parts[1]) else {
            return nil
        }
        return index
    }

    /// Elapsed time since meeting started.
    var elapsed: TimeInterval {
        capture.elapsed
    }

    // MARK: - Auto-update title

    /// Known meeting app bundle IDs to scan when no specific app was detected.
    /// Native meeting apps are checked first, browsers last (to avoid grabbing Slack tabs etc.)
    private static let nativeMeetingAppBundleIDs = [
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.apple.FaceTime",
        "com.cisco.webexmeetingsapp",
    ]

    private static let browserBundleIDs = [
        "com.brave.Browser",
        "com.google.Chrome",
        "company.thebrowser.Browser",  // Arc
        "com.apple.Safari",
        "org.mozilla.firefox",
    ]

    /// Try to update the meeting title from the detected meeting app,
    /// or by scanning known meeting apps if none was detected.
    private func autoUpdateTitleFromDetectedMeetingApp() {
        guard !hasAutoUpdatedTitle, isActive else { return }
        // Only update if user hasn't edited the name
        guard transcript.meetingName == originalName else { return }

        // Try the detected app first, then fall back to scanning known meeting apps
        let appsToCheck: [(app: NSRunningApplication, name: String)]
        if let detectedMeetingBundleIdentifier,
           let detectedMeetingAppName,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: detectedMeetingBundleIdentifier).first {
            appsToCheck = [(app, detectedMeetingAppName)]
        } else {
            appsToCheck = (Self.nativeMeetingAppBundleIDs + Self.browserBundleIDs).compactMap { bundleID in
                guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return nil }
                return (app, app.localizedName ?? "Meeting")
            }
        }

        for (meetingApp, appName) in appsToCheck {
            let titles = AccessibilityWindowTitles.all(for: meetingApp)
            if let cleaned = MeetingWindowHeuristics.bestAutoUpdateTitle(
                in: titles,
                appName: appName,
                observedBundleIdentifier: meetingApp.bundleIdentifier,
                monitoredBundleIdentifier: meetingApp.bundleIdentifier
            ) {
                hasAutoUpdatedTitle = true
                transcript.meetingName = cleaned
                print("MeetingSession: auto-updated title to '\(cleaned)' from \(appName)")
                autoSave()
                return
            }
        }
    }

    // MARK: - Calendar integration

    /// Populate meeting title and attendees from Google Calendar if connected.
    private func populateFromCalendar() async {
        guard GoogleCalendarService.shared.isSignedIn else { return }
        guard let event = await GoogleCalendarService.shared.currentMeeting() else {
            print("MeetingSession: no current calendar event found")
            return
        }

        // Set title from calendar if user hasn't edited it
        if transcript.meetingName == originalName {
            transcript.meetingName = event.title
            hasAutoUpdatedTitle = true
            print("MeetingSession: title set from calendar: '\(event.title)'")
        }

        // Set attendees from calendar
        if transcript.attendees.isEmpty && !event.attendees.isEmpty {
            transcript.attendees = event.attendees
            print("MeetingSession: attendees set from calendar: \(event.attendees.joined(separator: ", "))")
        }

        autoSave()
    }

    /// Manually trigger title detection and attendee capture.
    /// Briefly activates the meeting app so OCR captures its window, not Ghost Pepper's.
    func refreshTitleAndAttendees() {
        // Reset the flag so title detection retries
        hasAutoUpdatedTitle = false
        autoUpdateTitleFromDetectedMeetingApp()

        // Find the meeting app to bring to front for OCR.
        // Priority: detected app > native meeting apps > browsers > frontmost app.
        let meetingApp: NSRunningApplication? = {
            if let bundleID = detectedMeetingBundleIdentifier {
                return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
            }
            // Check native meeting apps first (Zoom, Teams, FaceTime, Webex)
            for bundleID in Self.nativeMeetingAppBundleIDs {
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                    return app
                }
            }
            // Fall back to browsers (for Google Meet, Zoom Web)
            for bundleID in Self.browserBundleIDs {
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                    return app
                }
            }
            return nil
        }()

        Task {
            if let meetingApp {
                meetingApp.activate()
                // Wait for the window to come to front
                try? await Task.sleep(nanoseconds: 800_000_000)
                print("MeetingSession: Detect activated \(meetingApp.localizedName ?? "app") for OCR")
            } else {
                print("MeetingSession: Detect found no meeting app to activate")
            }
            await captureAttendees()
            // Bring Ghost Pepper back to front
            try? await Task.sleep(nanoseconds: 200_000_000)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Attendee capture

    /// OCR the meeting window to extract participant names.
    /// Retries will merge new names with existing ones (people join late).
    private func captureAttendees() async {
        guard isActive else { return }

        guard let context = await ocrService.captureContext(customWords: []) else {
            print("MeetingSession: attendee OCR returned no context")
            return
        }
        let text = context.windowContents
        print("MeetingSession: attendee OCR captured \(text.count) chars from window")
        print("MeetingSession: OCR text preview: \(String(text.prefix(300)))")

        let names = Self.extractAttendeeNames(from: text)
        print("MeetingSession: extracted \(names.count) names: \(names)")
        guard !names.isEmpty else { return }

        // Merge with existing attendees (preserving order, no duplicates)
        let existing = Set(transcript.attendees)
        let newNames = names.filter { !existing.contains($0) }
        if !newNames.isEmpty {
            transcript.attendees.append(contentsOf: newNames)
            print("MeetingSession: captured attendees: \(transcript.attendees.joined(separator: ", "))")
            autoSave()
        }
    }

    /// Parse attendee names from OCR text of a meeting window.
    /// Zoom shows names as labels on video tiles, Teams shows them in participant panels.
    /// Heuristic: look for lines that look like person names (2-3 capitalized words, no special chars).
    static func extractAttendeeNames(from ocrText: String) -> [String] {
        let lines = ocrText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var names: [String] = []
        let namePattern = /^[A-Z][a-zA-Z'-]+(?:\s[A-Z][a-zA-Z'-]+){0,3}$/

        // Words that indicate a line is UI text, not a person's name
        let uiWords: Set<String> = [
            "mute", "unmute", "share", "screen", "chat", "record", "recording",
            "participants", "leave", "end", "meeting", "settings", "audio",
            "video", "gallery", "speaker", "view", "reactions", "more",
            "invite", "security", "breakout", "rooms", "host", "co-host",
            "waiting", "room", "zoom", "teams", "join", "start", "stop",
            "raise", "hand", "rename", "remove", "admit", "close", "minimize",
        ]

        for line in lines {
            // Strip parenthesized suffixes: pronouns, (You), (Host), etc.
            var candidate = line
            while let range = candidate.range(of: #"\s*\([^)]*\)"#, options: .regularExpression) {
                candidate.removeSubrange(range)
            }
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)

            // Skip single words (likely UI elements)
            let words = candidate.split(separator: " ")
            guard words.count >= 2, words.count <= 4 else { continue }

            // Skip lines with UI keywords
            let lower = candidate.lowercased()
            if uiWords.contains(where: { lower.contains($0) }) { continue }

            // Skip lines with numbers, special chars (timestamps, IDs, etc.)
            if candidate.contains(where: { $0.isNumber }) { continue }
            if candidate.contains("@") || candidate.contains("http") || candidate.contains("://") { continue }

            // Match name pattern: capitalized words
            if candidate.wholeMatch(of: namePattern) != nil {
                if !candidate.isEmpty && !names.contains(candidate) {
                    names.append(candidate)
                }
            }
        }

        return names
    }

    // MARK: - Auto-save

    private func autoSave() {
        do {
            let url = try MeetingMarkdownWriter.write(
                transcript: transcript,
                to: saveDirectory,
                existingFileURL: fileURL
            )
            if fileURL == nil {
                fileURL = url
                print("MeetingSession: transcript file created at \(url.path)")
            }
        } catch {
            print("MeetingSession: failed to save transcript — \(error.localizedDescription)")
        }
    }

    private func startMeetingEndMonitorIfNeeded() {
        guard supportsAutomaticEndDetection else { return }

        meetingEndCheckTimer?.invalidate()
        meetingEndCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkForMeetingEnd()
            }
        }
    }

    private var supportsAutomaticEndDetection: Bool {
        if detectedMeetingAppName == "Zoom" &&
            (detectedMeetingBundleIdentifier?.hasPrefix("us.zoom.") ?? false) {
            return true
        }
        if detectedMeetingAppName == "Microsoft Teams" &&
            (detectedMeetingBundleIdentifier?.contains("teams") ?? false) {
            return true
        }
        return false
    }

    private func checkForMeetingEnd() {
        guard isActive,
              let detectedMeetingAppName,
              let detectedMeetingBundleIdentifier else { return }

        // For Teams, check power assertion (most reliable)
        if detectedMeetingAppName == "Microsoft Teams" {
            if !isTeamsCallActive() {
                inactiveMeetingPollCount += 1
                guard inactiveMeetingPollCount >= 2 else { return }
                requestAutomaticStop(reason: "Teams call ended (power assertion released)")
            } else {
                inactiveMeetingPollCount = 0
            }
            return
        }

        // For Zoom and others, check if app is running and window titles
        guard let meetingApp = NSRunningApplication.runningApplications(withBundleIdentifier: detectedMeetingBundleIdentifier).first else {
            requestAutomaticStop(reason: "\(detectedMeetingAppName) is no longer running")
            return
        }

        let titles = AccessibilityWindowTitles.all(for: meetingApp)
        if MeetingWindowHeuristics.indicatesActiveMeeting(in: titles, appName: detectedMeetingAppName) {
            inactiveMeetingPollCount = 0
            return
        }

        inactiveMeetingPollCount += 1
        guard inactiveMeetingPollCount >= 2 else { return }
        requestAutomaticStop(reason: "meeting windows no longer look active")
    }
    
    /// Returns true if Microsoft Teams currently holds a "Call in progress"
    /// power assertion. For the *stop* path the fail-safe is "still active":
    /// a momentary failure to read pmset must never end an in-progress
    /// recording. Only a clean "no call" reading stops the session.
    private func isTeamsCallActive() -> Bool {
        let result = TeamsCallAssertion.query()
        switch result.state {
        case .callActive:
            return true
        case .noCall:
            return false
        case .unreadable:
            print("MeetingSession: pmset unreadable, assuming Teams call still active")
            return true
        }
    }

    private func requestAutomaticStop(reason: String) {
        guard isActive else { return }
        meetingEndCheckTimer?.invalidate()
        meetingEndCheckTimer = nil
        inactiveMeetingPollCount = 0
        print("MeetingSession: automatic stop requested — \(reason)")
        if let onAutoStopRequested {
            onAutoStopRequested(self)
            return
        }

        Task { @MainActor [weak self] in
            await self?.stop()
        }
    }
}
