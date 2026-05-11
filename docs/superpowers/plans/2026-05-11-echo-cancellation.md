# Echo Cancellation for Meeting Transcription

**Date**: 2026-05-11  
**Status**: In Progress  
**Priority**: High

## Problem Statement

When using Ghost Pepper's meeting feature without a headset (built-in speakers + microphone), the microphone picks up audio from other speakers playing through the computer's speakers. This audio is then transcribed as the user's own input, resulting in duplicate transcript entries:

- Remote speaker says something → transcribed as "Others"
- Same audio loops back through mic → transcribed as "Me"
- Result: Every statement appears twice with unclear attribution

### Example from Real Transcript

```
**[00:00] Me:** technical debt is something that simply goes away...
**[00:00] Others:** that is something that simply goes away...
```

## Root Cause Analysis

### Current Architecture
1. **DualStreamCapture** captures two independent audio streams:
   - Mic stream via `AudioRecorder` (AVAudioEngine) → labeled "Me"
   - System audio via `SystemAudioRecorder` (ScreenCaptureKit) → labeled "Others"

2. **ChunkedTranscriptionPipeline** processes both streams independently:
   - No cross-stream analysis
   - No echo detection
   - No awareness of audio similarity

3. **Audio Loopback Path**:
   ```
   Remote Speaker → System Audio → Speakers → Air → Microphone → "Me" transcription
   ```

## Solution Design

### Multi-Layered Echo Cancellation Approach

#### Layer 1: Audio Signal Analysis (Primary)
- **Cross-correlation detection** between mic and system audio chunks
- Detect time-delayed similarity (typical echo delay: 50-200ms)
- Calculate correlation coefficient to identify loopback
- Threshold: >0.7 correlation = likely echo

#### Layer 2: Transcript Deduplication (Secondary)
- **Fuzzy text matching** between "Me" and "Others" segments
- Use Levenshtein distance or similar algorithm
- Compare segments with overlapping time windows (±5 seconds)
- Threshold: >80% similarity = duplicate, suppress "Me" version

#### Layer 3: Adaptive Detection (Smart)
- **Audio level monitoring**:
  - High system audio + high mic audio = likely echo scenario
  - High mic audio + low system audio = genuine user speech
- **Pattern learning**:
  - Track correlation patterns over session
  - Adapt thresholds based on environment

#### Layer 4: User Configuration
- Settings toggle: Enable/Disable echo cancellation
- Sensitivity slider: Conservative → Aggressive
- Real-time echo detection indicator in UI
- Manual override for edge cases

## Implementation Plan

### Phase 1: Core Echo Detection Engine
**File**: `GhostPepper/Audio/EchoCancellationEngine.swift`

```swift
final class EchoCancellationEngine {
    struct EchoDetectionResult {
        let isEcho: Bool
        let confidence: Double // 0.0 - 1.0
        let correlationCoefficient: Double
        let timeLag: TimeInterval
    }
    
    func detectEcho(
        micSamples: [Float],
        systemSamples: [Float],
        sampleRate: Double
    ) -> EchoDetectionResult
    
    func shouldSuppressTranscript(
        micText: String,
        systemText: String,
        micTime: TimeInterval,
        systemTime: TimeInterval
    ) -> Bool
}
```

### Phase 2: Integration with ChunkedTranscriptionPipeline
- Add echo detection before transcription
- Tag segments with echo confidence
- Suppress high-confidence echo segments
- Preserve original audio for debugging

### Phase 3: Settings & UI
- Add echo cancellation settings to preferences
- Show echo detection status in meeting window
- Add debug mode to visualize correlation

### Phase 4: Testing & Refinement
- Test with various audio setups (speakers, headsets, AirPods)
- Collect correlation data to tune thresholds
- A/B test with real meeting transcripts

## Technical Details

### Cross-Correlation Algorithm

```swift
func crossCorrelation(signal1: [Float], signal2: [Float], maxLag: Int) -> (coefficient: Double, lag: Int) {
    // Normalize signals
    let norm1 = normalize(signal1)
    let norm2 = normalize(signal2)
    
    var maxCorr: Double = 0
    var bestLag: Int = 0
    
    // Search for best correlation within lag window
    for lag in 0..<maxLag {
        let corr = correlate(norm1, norm2, lag: lag)
        if corr > maxCorr {
            maxCorr = corr
            bestLag = lag
        }
    }
    
    return (maxCorr, bestLag)
}
```

### Text Similarity (Levenshtein Distance)

```swift
func textSimilarity(_ text1: String, _ text2: String) -> Double {
    let distance = levenshteinDistance(text1, text2)
    let maxLen = max(text1.count, text2.count)
    return 1.0 - (Double(distance) / Double(maxLen))
}
```

## Configuration Options

### UserDefaults Keys
- `echoCancellationEnabled`: Bool (default: true)
- `echoCancellationSensitivity`: Double (0.0-1.0, default: 0.7)
- `echoCancellationDebugMode`: Bool (default: false)

### Sensitivity Levels
- **Conservative (0.5)**: Only suppress obvious echoes, may miss some
- **Balanced (0.7)**: Recommended default
- **Aggressive (0.9)**: Suppress more aggressively, may catch false positives

## Success Metrics

1. **Duplicate Reduction**: Reduce duplicate transcript entries by >90%
2. **False Positive Rate**: <5% of genuine user speech suppressed
3. **Performance**: <10ms additional latency per chunk
4. **User Satisfaction**: Positive feedback from beta testers

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| False positives (suppress real speech) | High | Conservative defaults, user override |
| Performance overhead | Medium | Optimize correlation algorithm, use SIMD |
| Edge cases (unusual audio setups) | Medium | Extensive testing, debug mode |
| Complexity | Low | Modular design, comprehensive tests |

## Future Enhancements

1. **Machine Learning**: Train model to detect echo patterns
2. **Acoustic Echo Cancellation (AEC)**: Real-time signal processing
3. **Speaker Identification**: Use voice fingerprinting for better attribution
4. **Adaptive Learning**: Improve detection over time per user

## References

- [Acoustic Echo Cancellation Overview](https://en.wikipedia.org/wiki/Echo_suppression_and_cancellation)
- [Cross-Correlation for Audio Alignment](https://www.dsprelated.com/freebooks/sasp/Cross_Correlation.html)
- [Levenshtein Distance Algorithm](https://en.wikipedia.org/wiki/Levenshtein_distance)