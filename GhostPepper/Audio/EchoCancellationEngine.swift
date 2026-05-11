import Foundation
import Accelerate

/// Detects and suppresses audio echo/loopback in dual-stream meeting capture.
/// When using speakers + mic (no headset), the mic picks up system audio playing
/// through speakers, creating duplicate transcriptions. This engine identifies
/// and suppresses those duplicates using audio correlation and text similarity.
final class EchoCancellationEngine {
    
    // MARK: - Configuration
    
    struct Configuration {
        /// Enable/disable echo cancellation globally
        var enabled: Bool = true
        
        /// Correlation threshold for audio similarity (0.0-1.0)
        /// Higher = more conservative (fewer false positives, may miss some echoes)
        var audioCorrelationThreshold: Double = 0.7
        
        /// Text similarity threshold for transcript deduplication (0.0-1.0)
        var textSimilarityThreshold: Double = 0.8
        
        /// Maximum time lag to search for echo (seconds)
        /// Typical speaker→mic delay is 50-200ms
        var maxEchoLagSeconds: TimeInterval = 0.3
        
        /// Minimum audio duration to analyze (seconds)
        /// Skip very short chunks to avoid false positives
        var minimumChunkDuration: TimeInterval = 0.5
        
        /// RMS threshold for "silence" detection
        /// Audio below this level is considered silence and skipped
        var silenceThreshold: Float = 0.001
        
        static let `default` = Configuration()
        
        /// Conservative preset: only suppress obvious echoes
        static let conservative = Configuration(
            audioCorrelationThreshold: 0.85,
            textSimilarityThreshold: 0.9
        )
        
        /// Aggressive preset: suppress more aggressively
        static let aggressive = Configuration(
            audioCorrelationThreshold: 0.6,
            textSimilarityThreshold: 0.7
        )
    }
    
    // MARK: - Results
    
    struct EchoDetectionResult {
        /// Whether echo was detected
        let isEcho: Bool
        
        /// Confidence level (0.0-1.0)
        let confidence: Double
        
        /// Audio correlation coefficient
        let audioCorrelation: Double
        
        /// Time lag between system and mic audio (seconds)
        let timeLag: TimeInterval
        
        /// RMS levels for diagnostics
        let micRMS: Float
        let systemRMS: Float
        
        /// Debug description
        var debugDescription: String {
            """
            Echo: \(isEcho), Confidence: \(String(format: "%.2f", confidence)), \
            Correlation: \(String(format: "%.3f", audioCorrelation)), \
            Lag: \(String(format: "%.3f", timeLag))s, \
            Mic RMS: \(String(format: "%.4f", micRMS)), \
            System RMS: \(String(format: "%.4f", systemRMS))
            """
        }
    }
    
    struct TextDeduplicationResult {
        /// Whether texts are duplicates
        let isDuplicate: Bool
        
        /// Similarity score (0.0-1.0)
        let similarity: Double
        
        /// Which text to keep (if duplicate)
        let preferredSource: AudioStreamSource?
        
        var debugDescription: String {
            """
            Duplicate: \(isDuplicate), Similarity: \(String(format: "%.2f", similarity)), \
            Preferred: \(preferredSource?.debugName ?? "none")
            """
        }
    }
    
    // MARK: - Properties
    
    private let config: Configuration
    private let sampleRate: Double
    
    init(config: Configuration = .default, sampleRate: Double = 16000) {
        self.config = config
        self.sampleRate = sampleRate
    }
    
    // MARK: - Audio Analysis
    
    /// Detect if mic audio is an echo of system audio using cross-correlation.
    func detectEcho(
        micSamples: [Float],
        systemSamples: [Float]
    ) -> EchoDetectionResult {
        guard config.enabled else {
            return EchoDetectionResult(
                isEcho: false,
                confidence: 0,
                audioCorrelation: 0,
                timeLag: 0,
                micRMS: 0,
                systemRMS: 0
            )
        }
        
        // Calculate RMS levels
        let micRMS = calculateRMS(micSamples)
        let systemRMS = calculateRMS(systemSamples)
        
        // Skip if either stream is silent
        guard micRMS > config.silenceThreshold,
              systemRMS > config.silenceThreshold else {
            return EchoDetectionResult(
                isEcho: false,
                confidence: 0,
                audioCorrelation: 0,
                timeLag: 0,
                micRMS: micRMS,
                systemRMS: systemRMS
            )
        }
        
        // Skip if chunks are too short
        let duration = Double(min(micSamples.count, systemSamples.count)) / sampleRate
        guard duration >= config.minimumChunkDuration else {
            return EchoDetectionResult(
                isEcho: false,
                confidence: 0,
                audioCorrelation: 0,
                timeLag: 0,
                micRMS: micRMS,
                systemRMS: systemRMS
            )
        }
        
        // Compute cross-correlation
        let maxLagSamples = Int(config.maxEchoLagSeconds * sampleRate)
        let (correlation, lagSamples) = crossCorrelation(
            signal1: systemSamples,
            signal2: micSamples,
            maxLag: maxLagSamples
        )
        
        let timeLag = Double(lagSamples) / sampleRate
        
        // Determine if this is echo based on correlation threshold
        let isEcho = correlation >= config.audioCorrelationThreshold
        
        // Confidence is based on how far above threshold we are
        let confidence = isEcho ? min(1.0, correlation / config.audioCorrelationThreshold) : 0.0
        
        return EchoDetectionResult(
            isEcho: isEcho,
            confidence: confidence,
            audioCorrelation: correlation,
            timeLag: timeLag,
            micRMS: micRMS,
            systemRMS: systemRMS
        )
    }
    
    // MARK: - Text Analysis
    
    /// Detect if two transcript segments are duplicates using text similarity.
    func detectDuplicateTranscript(
        micText: String,
        systemText: String,
        micTime: TimeInterval,
        systemTime: TimeInterval
    ) -> TextDeduplicationResult {
        guard config.enabled else {
            return TextDeduplicationResult(
                isDuplicate: false,
                similarity: 0,
                preferredSource: nil
            )
        }
        
        // Skip if either text is empty
        guard !micText.isEmpty, !systemText.isEmpty else {
            return TextDeduplicationResult(
                isDuplicate: false,
                similarity: 0,
                preferredSource: nil
            )
        }
        
        // Check if time windows overlap (within ±5 seconds)
        let timeOverlap = abs(micTime - systemTime) <= 5.0
        guard timeOverlap else {
            return TextDeduplicationResult(
                isDuplicate: false,
                similarity: 0,
                preferredSource: nil
            )
        }
        
        // Calculate text similarity
        let similarity = textSimilarity(micText, systemText)
        
        // Determine if duplicate based on threshold
        let isDuplicate = similarity >= config.textSimilarityThreshold
        
        // Always prefer system audio (authoritative source)
        let preferredSource: AudioStreamSource? = isDuplicate ? .system : nil
        
        return TextDeduplicationResult(
            isDuplicate: isDuplicate,
            similarity: similarity,
            preferredSource: preferredSource
        )
    }
    
    // MARK: - Private Helpers
    
    /// Calculate RMS (Root Mean Square) amplitude of audio samples.
    private func calculateRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return rms
    }
    
    /// Compute cross-correlation between two signals to detect similarity and time lag.
    /// Returns (correlation coefficient, lag in samples).
    private func crossCorrelation(
        signal1: [Float],
        signal2: [Float],
        maxLag: Int
    ) -> (correlation: Double, lag: Int) {
        // Normalize signals to zero mean and unit variance
        let norm1 = normalize(signal1)
        let norm2 = normalize(signal2)
        
        let minLen = min(norm1.count, norm2.count)
        guard minLen > maxLag else {
            return (0, 0)
        }
        
        var maxCorr: Double = 0
        var bestLag: Int = 0
        
        // Search for best correlation within lag window
        // Positive lag means signal2 (mic) is delayed relative to signal1 (system)
        for lag in 0..<min(maxLag, minLen / 2) {
            let corr = correlate(norm1, norm2, lag: lag, length: minLen - lag)
            if corr > maxCorr {
                maxCorr = corr
                bestLag = lag
            }
        }
        
        return (maxCorr, bestLag)
    }
    
    /// Normalize signal to zero mean and unit variance.
    private func normalize(_ signal: [Float]) -> [Float] {
        guard !signal.isEmpty else { return [] }
        
        // Calculate mean
        var mean: Float = 0
        vDSP_meanv(signal, 1, &mean, vDSP_Length(signal.count))
        
        // Subtract mean
        var zeroMean = [Float](repeating: 0, count: signal.count)
        var negMean = -mean
        vDSP_vsadd(signal, 1, &negMean, &zeroMean, 1, vDSP_Length(signal.count))
        
        // Calculate standard deviation
        var variance: Float = 0
        vDSP_measqv(zeroMean, 1, &variance, vDSP_Length(signal.count))
        let stdDev = sqrt(variance)
        
        guard stdDev > 0 else { return zeroMean }
        
        // Divide by standard deviation
        var normalized = [Float](repeating: 0, count: signal.count)
        var divisor = stdDev
        vDSP_vsdiv(zeroMean, 1, &divisor, &normalized, 1, vDSP_Length(signal.count))
        
        return normalized
    }
    
    /// Compute correlation coefficient between two normalized signals at a given lag.
    private func correlate(_ signal1: [Float], _ signal2: [Float], lag: Int, length: Int) -> Double {
        guard length > 0, lag + length <= signal2.count, length <= signal1.count else {
            return 0
        }
        
        // Compute dot product of overlapping regions
        var dotProduct: Float = 0
        vDSP_dotpr(
            signal1, 1,
            Array(signal2[lag..<(lag + length)]), 1,
            &dotProduct,
            vDSP_Length(length)
        )
        
        // Normalize by length to get correlation coefficient
        return Double(dotProduct) / Double(length)
    }
    
    /// Calculate text similarity using normalized Levenshtein distance.
    /// Returns value between 0.0 (completely different) and 1.0 (identical).
    private func textSimilarity(_ text1: String, _ text2: String) -> Double {
        // Normalize: lowercase, trim whitespace
        let s1 = text1.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let s2 = text2.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !s1.isEmpty, !s2.isEmpty else { return 0 }
        
        // Quick check: if strings are identical, return 1.0
        if s1 == s2 { return 1.0 }
        
        // Compute Levenshtein distance
        let distance = levenshteinDistance(s1, s2)
        let maxLen = max(s1.count, s2.count)
        
        // Convert distance to similarity (0.0 = different, 1.0 = same)
        return 1.0 - (Double(distance) / Double(maxLen))
    }
    
    /// Compute Levenshtein distance (edit distance) between two strings.
    private func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let m = s1.count
        let n = s2.count
        
        guard m > 0 else { return n }
        guard n > 0 else { return m }
        
        // Create distance matrix
        var matrix = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        
        // Initialize first row and column
        for i in 0...m { matrix[i][0] = i }
        for j in 0...n { matrix[0][j] = j }
        
        let s1Array = Array(s1)
        let s2Array = Array(s2)
        
        // Fill matrix using dynamic programming
        for i in 1...m {
            for j in 1...n {
                let cost = s1Array[i - 1] == s2Array[j - 1] ? 0 : 1
                matrix[i][j] = min(
                    matrix[i - 1][j] + 1,      // deletion
                    matrix[i][j - 1] + 1,      // insertion
                    matrix[i - 1][j - 1] + cost // substitution
                )
            }
        }
        
        return matrix[m][n]
    }
}

// MARK: - Extensions

private extension AudioStreamSource {
    var debugName: String {
        switch self {
        case .mic: return "mic"
        case .system: return "system"
        }
    }
}

// Made with Bob
