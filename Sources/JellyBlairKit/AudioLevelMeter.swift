import Accelerate
import AVFoundation
import Foundation
import QuartzCore

/// Measures per-band levels of the playing audio from the buffers the audio
/// tap hands it. The capture only copies samples, on the audio render
/// thread. The transform runs in currentBands(), so audio that nothing
/// displays costs nothing.
public final class AudioLevelMeter {
    public static let bandCount = bandLowerFrequencies.count

    private static let fftSize = 512
    private static let fftSizeLog2: vDSP_Length = 9

    /// Band amplitudes map to bars on a decibel scale between these bounds,
    /// so speech rides mid-scale instead of pegging the energetic low bands.
    private static let floorDecibels: Float = -60
    private static let ceilingDecibels: Float = -20

    /// Lower frequency bounds of the bands in hertz, roughly logarithmic
    /// across speech frequencies. Each band runs up to the next bound, and
    /// the last band runs up to the Nyquist frequency.
    private static let bandLowerFrequencies: [Float] = [86, 500, 2500]

    /// Stands in for the stream's sample rate until the tap's prepare
    /// callback reports one, so the bin math never divides by zero.
    private static let fallbackSampleRate: Float = 44100

    /// The FFT bin range of each band at the given sample rate, so the bands
    /// cover the same frequencies for every stream format.
    private static func bandBinRanges(sampleRate: Float) -> [Range<Int>] {
        let binWidth = sampleRate / Float(fftSize)
        let lowerBins = bandLowerFrequencies.map { min(max(Int($0 / binWidth), 1), fftSize / 2) }
        let upperBins = lowerBins.dropFirst() + [fftSize / 2]
        return zip(lowerBins, upperBins).map { $0..<max($0, $1) }
    }

    /// The fraction of a band's distance to its target that remains after one
    /// second, one rate for rising and one for falling. Time-based smoothing
    /// keeps the motion the same at any read rate. The rise rate covers the
    /// gap in tens of milliseconds, so attacks still look immediate.
    private static let riseRemainderPerSecond: Float = 1e-20
    private static let fallRemainderPerSecond: Float = 0.0002

    /// Guards the captured samples, which the audio thread writes and the
    /// reader takes, and the sample rate, which the tap's prepare callback
    /// writes.
    private let lock = NSLock()
    private var capturedSamples = [Float](repeating: 0, count: AudioLevelMeter.fftSize)
    private var hasCapturedSamples = false

    /// False while nothing can display the bars; each capture then returns
    /// at once.
    private var isCapturing = true

    /// The sample rate of the prepared stream.
    private var sampleRate: Float = 0

    /// Buffers the reader alone touches, held so that no read allocates.
    /// The reader runs on the main actor, so these need no lock.
    private var samples = [Float](repeating: 0, count: AudioLevelMeter.fftSize)
    private var real = [Float](repeating: 0, count: AudioLevelMeter.fftSize / 2)
    private var imaginary = [Float](repeating: 0, count: AudioLevelMeter.fftSize / 2)
    private var magnitudes = [Float](repeating: 0, count: AudioLevelMeter.fftSize / 2)
    private var bands = [Float](repeating: 0, count: AudioLevelMeter.bandCount)
    private var targetBands = [Float](repeating: 0, count: AudioLevelMeter.bandCount)
    private var lastReadTime: TimeInterval?

    /// The bin ranges for the sample rate last seen, rebuilt on a change so
    /// that no steady-state read allocates.
    private var binRanges: [Range<Int>] = []
    private var binRangesSampleRate: Float = 0

    private let fftSetup: FFTSetup

    init() {
        fftSetup = vDSP_create_fftsetup(Self.fftSizeLog2, FFTRadix(kFFTRadix2))!
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// The current band levels. A new captured buffer moves the targets, and
    /// every read moves the levels toward them, so the motion is smooth at
    /// the read rate even though buffers arrive far less often.
    @MainActor
    public func currentBands() -> [Float] {
        if takeCapturedSamples() {
            transformSamples()
            updateTargetBands()
        }
        moveBandsTowardTargets()
        return bands
    }

    @MainActor
    func reset() {
        lock.lock()
        hasCapturedSamples = false
        lock.unlock()
        bands = [Float](repeating: 0, count: Self.bandCount)
        targetBands = [Float](repeating: 0, count: Self.bandCount)
        lastReadTime = nil
    }

    /// Turns capturing on or off.
    @MainActor
    func setCapturing(_ capturing: Bool) {
        lock.lock()
        isCapturing = capturing
        lock.unlock()
    }

    // MARK: - Capture

    func setSampleRate(_ rate: Float) {
        lock.lock()
        sampleRate = rate
        lock.unlock()
    }

    /// Copies one buffer of audio aside for the next read. Runs on the audio
    /// render thread, so it checks the buffer and copies it, nothing more.
    func capture(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        lock.lock()
        let readable = isCapturing
        lock.unlock()
        guard readable else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard let first = buffers.first(where: { $0.mData != nil }) else { return }
        let sampleCapacity = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        let count = min(frameCount, sampleCapacity, Self.fftSize)
        guard count >= 64 else { return }
        let source = first.mData!.assumingMemoryBound(to: Float.self)
        lock.lock()
        capturedSamples.withUnsafeMutableBufferPointer { destination in
            destination.update(repeating: 0)
            destination.baseAddress!.update(from: source, count: count)
        }
        hasCapturedSamples = true
        lock.unlock()
    }

    // MARK: - Measurement

    /// Moves the newest captured buffer into the reader's buffer, and reports
    /// whether one arrived since the last read.
    private func takeCapturedSamples() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard hasCapturedSamples else { return false }
        hasCapturedSamples = false
        samples.withUnsafeMutableBufferPointer { destination in
            capturedSamples.withUnsafeBufferPointer { source in
                destination.baseAddress!.update(from: source.baseAddress!, count: Self.fftSize)
            }
        }
        return true
    }

    /// Fills the magnitudes with the samples' power spectrum.
    private func transformSamples() {
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                samples.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(Self.fftSize / 2))
                }
                vDSP_fft_zrip(fftSetup, &split, 1, Self.fftSizeLog2, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(Self.fftSize / 2))
            }
        }
    }

    /// The bin ranges for the stream's sample rate, rebuilt when it changes.
    private func currentBandBinRanges() -> [Range<Int>] {
        lock.lock()
        let rate = sampleRate > 0 ? sampleRate : Self.fallbackSampleRate
        lock.unlock()
        if rate != binRangesSampleRate {
            binRanges = Self.bandBinRanges(sampleRate: rate)
            binRangesSampleRate = rate
        }
        return binRanges
    }

    /// Folds the magnitudes into the bars' target levels.
    private func updateTargetBands() {
        for (index, range) in currentBandBinRanges().enumerated() {
            // A very low sample rate can push a band past Nyquist and leave
            // its range empty, so the band rests instead of dividing by zero.
            guard !range.isEmpty else {
                targetBands[index] = 0
                continue
            }
            let meanPower = magnitudes[range].reduce(0, +) / Float(range.count)
            let amplitude = sqrt(meanPower) / Float(Self.fftSize)
            let decibels = 20 * log10(max(amplitude, 1e-7))
            let level = (decibels - Self.floorDecibels) / (Self.ceilingDecibels - Self.floorDecibels)
            // Unexpected sample content can turn the math non-finite, and a
            // non-finite band would crash layout as a NaN view height.
            targetBands[index] = level.isFinite ? min(1, max(0, level)) : 0
        }
    }

    /// Moves each level part of the way to its target, by the time since the
    /// last read. Fast attack with slow decay reads as natural motion.
    private func moveBandsTowardTargets() {
        let now = CACurrentMediaTime()
        let elapsed = lastReadTime.map { now - $0 } ?? 0
        lastReadTime = now
        let rise = pow(Self.riseRemainderPerSecond, Float(elapsed))
        let fall = pow(Self.fallRemainderPerSecond, Float(elapsed))
        for index in 0..<Self.bandCount {
            let target = targetBands[index]
            let remainder = target > bands[index] ? rise : fall
            bands[index] = target + (bands[index] - target) * remainder
        }
    }
}
