# Meeting Detection Bug Fix

**Date**: 2026-05-13  
**Issue**: Teams meeting detection only fires once, then stops working until app restart

## Problem

Meeting detection for Microsoft Teams stopped working after the first detected call. The user reported:
- Debug log showed no entries for 2 days despite Ghost Pepper running
- Had several Teams meetings during that time
- No detection, no transcription started

## Root Cause

The bug was in [`GhostPepper/Meeting/MeetingDetector.swift`](../../GhostPepper/Meeting/MeetingDetector.swift) lines 154-167.

### Original Buggy Code

```swift
let teamsAssertionPresent = isTeamsCallActive()
if teamsAssertionPresent && !teamsAssertionWasPresentLastPoll {
    // Transition detected: Teams call just started.
    let teamsKey = "teams-assertion"
    if !dismissedBundleIDs.contains(teamsKey) {
        dismiss(bundleID: teamsKey)  // ← BUG: Dismisses BEFORE callback
        let meeting = DetectedMeeting(...)
        onMeetingDetected?(meeting)
    }
}
teamsAssertionWasPresentLastPoll = teamsAssertionPresent
```

### The Problem

1. **Premature dismissal**: `dismiss(bundleID: teamsKey)` was called BEFORE `onMeetingDetected?(meeting)`
2. **Permanent dismissal**: Once "teams-assertion" was added to `dismissedBundleIDs`, it stayed there forever
3. **No cleanup**: When the call ended (power assertion disappeared), the dismissal was never cleared
4. **Result**: First call detected ✅, all subsequent calls ignored ❌

### Timeline

1. **First Teams call**: Detection fires, adds "teams-assertion" to `dismissedBundleIDs`
2. **Call ends**: Power assertion disappears, but "teams-assertion" stays in `dismissedBundleIDs`
3. **Second Teams call**: Power assertion appears, but check fails because "teams-assertion" is already dismissed
4. **Forever broken**: Until app restart (which clears `dismissedBundleIDs`)

## Solution

### Fixed Code

```swift
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
        let meeting = DetectedMeeting(...)
        onMeetingDetected?(meeting)
        // Dismiss AFTER callback so it can handle the detection
        dismiss(bundleID: teamsKey)
    }
}
teamsAssertionWasPresentLastPoll = teamsAssertionPresent
```

### Key Changes

1. **Detect call end**: Added check for `!teamsAssertionPresent && teamsAssertionWasPresentLastPoll` (transition from call to no-call)
2. **Clear dismissal**: When call ends, remove "teams-assertion" from `dismissedBundleIDs`
3. **Reorder operations**: Move `dismiss()` call AFTER `onMeetingDetected?()` callback
4. **Result**: Each new call can be detected independently

## How It Works Now

### Call Lifecycle

1. **No call → Call starts**:
   - Power assertion appears
   - `teamsAssertionPresent = true`, `teamsAssertionWasPresentLastPoll = false`
   - Detection fires: `onMeetingDetected?(meeting)`
   - Dismissal added to prevent duplicate detection during same call

2. **Call active**:
   - Power assertion present
   - `teamsAssertionPresent = true`, `teamsAssertionWasPresentLastPoll = true`
   - No detection (no transition)

3. **Call ends**:
   - Power assertion disappears
   - `teamsAssertionPresent = false`, `teamsAssertionWasPresentLastPoll = true`
   - **NEW**: Dismissal cleared from `dismissedBundleIDs`

4. **Next call starts**:
   - Power assertion appears again
   - Detection fires again (dismissal was cleared) ✅

## Testing

To verify the fix:

1. **Build and run** the updated app
2. **Join a Teams call** → Should see "Meeting detected: Microsoft Teams" in Debug Log
3. **End the call** → Power assertion disappears
4. **Join another Teams call** → Should detect again (previously would fail)
5. **Check Debug Log** → Should see multiple "Meeting detected" entries

### Manual Test Commands

```bash
# Check if Teams call is active (while in a call)
pmset -g assertions | grep "Microsoft Teams Call in progress"

# Should output: "Microsoft Teams Call in progress"

# Check when not in a call
pmset -g assertions | grep "Microsoft Teams Call in progress"

# Should output nothing (exit code 1)
```

## Impact

- ✅ Teams detection now works for multiple calls per session
- ✅ No app restart required between calls
- ✅ Dismissal logic still prevents duplicate detection during same call
- ✅ Other meeting apps (Zoom, FaceTime, etc.) unaffected

## Related Files

- [`GhostPepper/Meeting/MeetingDetector.swift`](../../GhostPepper/Meeting/MeetingDetector.swift) - Fixed detection logic
- [`GhostPepper/AppState.swift`](../../GhostPepper/AppState.swift) - Detection callback handler
- [`GhostPepper/Meeting/MeetingSession.swift`](../../GhostPepper/Meeting/MeetingSession.swift) - Auto-stop logic

## Notes

- This bug only affected Teams because Teams uses power assertion detection
- Other apps (Zoom, FaceTime) use frontmost app detection and weren't affected
- The `dismissedBundleIDs` mechanism is still useful to prevent duplicate prompts during the same call
- The fix maintains the original intent while allowing detection across multiple calls