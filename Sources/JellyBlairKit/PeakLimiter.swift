import Accelerate
import AVFoundation
import Foundation

/// Scales audio down whenever its peak crosses the stored ceiling, and lets
/// the gain recover over a short release. The processing runs on the audio
/// render thread, so it never allocates. The system volume scales the output
/// after this, so the ceiling is relative to the file, not the speaker.
///
/// The gain ramps across each buffer instead of looking ahead, so the first
/// few milliseconds of a loud passage pass partly limited.
final class PeakLimiter {
    /// The time for the gain to recover most of the way to unity after a
    /// loud passage ends.
    private static let releaseSeconds: Float = 0.3

    /// Stands in for the stream's sample rate until the tap's prepare
    /// callback reports one.
    private static let fallbackSampleRate: Float = 44100

    /// Guards the ceiling, which the main thread writes from the stored
    /// settings, and the sample rate, which the tap's prepare callback
    /// writes. The render thread reads both.
    private let lock = NSLock()
    private var ceiling: Float = 1
    private var sampleRate = PeakLimiter.fallbackSampleRate

    /// The gain applied to the last sample of the last buffer. The render
    /// thread alone touches it.
    private var gain: Float = 1

    private var settingsObserver: NSObjectProtocol?

    init() {
        readStoredCeiling()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.readStoredCeiling()
        }
    }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    private func readStoredCeiling() {
        let decibels = Float(LoudnessLimit.ceilingDecibels)
        lock.lock()
        ceiling = pow(10, decibels / 20)
        lock.unlock()
    }

    func setSampleRate(_ rate: Float) {
        guard rate > 0 else { return }
        lock.lock()
        sampleRate = rate
        lock.unlock()
    }

    /// Limits every channel of the buffer list in place.
    func process(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        lock.lock()
        let ceiling = ceiling
        let sampleRate = sampleRate
        lock.unlock()
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        let target = targetGain(ceiling: ceiling, peak: peakAmplitude(of: buffers, frameCount: frameCount))
        let end = nextGain(toward: target, over: frameCount, sampleRate: sampleRate)
        applyGainRamp(from: gain, to: end, over: buffers, frameCount: frameCount)
        gain = end
    }

    /// The gain that puts the peak on the ceiling, or unity when it is
    /// already below.
    private func targetGain(ceiling: Float, peak: Float) -> Float {
        min(1, ceiling / max(peak, ceiling))
    }

    /// The largest absolute sample across every channel.
    private func peakAmplitude(of buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) -> Float {
        var peak: Float = 0
        for buffer in buffers {
            guard let samples = Self.samples(of: buffer) else { continue }
            let count = Self.sampleCount(of: buffer, frameCount: frameCount)
            var bufferPeak: Float = 0
            vDSP_maxmgv(samples, 1, &bufferPeak, vDSP_Length(count))
            peak = max(peak, bufferPeak)
        }
        return peak
    }

    /// Attacks at once, releases with an exponential decay whose length
    /// is fixed in seconds at any sample rate.
    private func nextGain(toward target: Float, over frameCount: Int, sampleRate: Float) -> Float {
        if target <= gain {
            return target
        }
        let remainder = exp(-Float(frameCount) / (sampleRate * Self.releaseSeconds))
        return target + (gain - target) * remainder
    }

    /// Multiplies every channel by a gain that moves linearly across the
    /// buffer's frames, so a gain change makes no click. Interleaved
    /// channels get the same gain within each frame.
    private func applyGainRamp(from start: Float, to end: Float, over buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        if start == 1, end == 1 {
            return
        }
        for buffer in buffers {
            guard let samples = Self.samples(of: buffer) else { continue }
            let channels = max(Int(buffer.mNumberChannels), 1)
            let frames = Self.sampleCount(of: buffer, frameCount: frameCount) / channels
            var start = start
            var step = frames > 1 ? (end - start) / Float(frames - 1) : 0
            for channel in 0..<channels {
                let channelSamples = samples + channel
                vDSP_vrampmul(channelSamples, channels, &start, &step, channelSamples, channels, vDSP_Length(frames))
            }
        }
    }

    private static func samples(of buffer: AudioBuffer) -> UnsafeMutablePointer<Float>? {
        buffer.mData?.assumingMemoryBound(to: Float.self)
    }

    /// The samples the buffer holds for the reported frames, bounded by the
    /// bytes it actually carries.
    private static func sampleCount(of buffer: AudioBuffer, frameCount: Int) -> Int {
        let capacity = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        return min(frameCount * max(Int(buffer.mNumberChannels), 1), capacity)
    }
}
