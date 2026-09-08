import Accelerate
import AVFoundation
import Foundation
import MediaToolbox

/// Measures per-band levels of the playing audio through an MTAudioProcessingTap.
/// The tap only captures samples, on the audio render thread. The transform
/// runs in currentBands(), so audio that nothing displays costs nothing.
public final class AudioLevelMeter {
    public static let bandCount = 3

    private static let fftSize = 512
    private static let fftSizeLog2: vDSP_Length = 9

    /// Band amplitudes map to bars on a decibel scale between these bounds,
    /// so speech rides mid-scale instead of pegging the energetic low bands.
    private static let floorDecibels: Float = -60
    private static let ceilingDecibels: Float = -20

    /// Bin ranges for the bands, roughly logarithmic across speech frequencies.
    private static let bandBinRanges: [Range<Int>] = [1..<12, 12..<64, 64..<256]

    /// Guards the captured samples, which the audio thread writes and the
    /// reader takes, and the format flag, which the tap's callbacks write.
    private let lock = NSLock()
    private var capturedSamples = [Float](repeating: 0, count: AudioLevelMeter.fftSize)
    private var hasCapturedSamples = false

    /// True while the prepared stream is 32-bit float PCM, the only format
    /// the tap can read. The tap's prepare callback writes it.
    private var formatIsFloat32 = false

    /// Buffers the reader alone touches, held so that no read allocates.
    /// The reader runs on the main actor, so these need no lock.
    private var samples = [Float](repeating: 0, count: AudioLevelMeter.fftSize)
    private var real = [Float](repeating: 0, count: AudioLevelMeter.fftSize / 2)
    private var imaginary = [Float](repeating: 0, count: AudioLevelMeter.fftSize / 2)
    private var magnitudes = [Float](repeating: 0, count: AudioLevelMeter.fftSize / 2)
    private var bands = [Float](repeating: 0, count: AudioLevelMeter.bandCount)

    private let fftSetup: FFTSetup

    init() {
        fftSetup = vDSP_create_fftsetup(Self.fftSizeLog2, FFTRadix(kFFTRadix2))!
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// The current band levels. Transforms the newest captured samples, so
    /// the work happens once for each read and not at all without one.
    @MainActor
    public func currentBands() -> [Float] {
        if takeCapturedSamples() {
            transformSamples()
            updateBands()
        }
        return bands
    }

    @MainActor
    func reset() {
        lock.lock()
        hasCapturedSamples = false
        lock.unlock()
        bands = [Float](repeating: 0, count: Self.bandCount)
    }

    // MARK: - Tap plumbing

    /// Builds an audio mix whose processing tap feeds this meter.
    func makeAudioMix(for track: AVAssetTrack) -> AVAudioMix? {
        // The tap retains the meter and releases it in finalize, so the audio
        // thread can never call into a deallocated meter.
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque()),
            init: { _, clientInfo, tapStorageOut in
                tapStorageOut.pointee = clientInfo!
            },
            finalize: { tap in
                Unmanaged<AudioLevelMeter>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let meter = Unmanaged<AudioLevelMeter>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                meter.noteFormat(format.pointee)
            },
            unprepare: { tap in
                let meter = Unmanaged<AudioLevelMeter>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                meter.forgetFormat()
            },
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
                guard status == noErr else { return }
                let meter = Unmanaged<AudioLevelMeter>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                meter.capture(bufferList: bufferListInOut, frameCount: Int(numberFramesOut.pointee))
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else { return nil }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }

    // MARK: - Capture

    private func noteFormat(_ format: AudioStreamBasicDescription) {
        let isFloat32 = format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mBitsPerChannel == 32
        lock.lock()
        formatIsFloat32 = isFloat32
        lock.unlock()
    }

    private func forgetFormat() {
        lock.lock()
        formatIsFloat32 = false
        lock.unlock()
    }

    /// Copies one buffer of audio aside for the next read. Runs on the audio
    /// render thread, so it checks the buffer and copies it, nothing more.
    private func capture(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        lock.lock()
        let readable = formatIsFloat32
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

    /// Folds the magnitudes into the bars' levels.
    private func updateBands() {
        for (index, range) in Self.bandBinRanges.enumerated() {
            let meanPower = magnitudes[range].reduce(0, +) / Float(range.count)
            let amplitude = sqrt(meanPower) / Float(Self.fftSize)
            let decibels = 20 * log10(max(amplitude, 1e-7))
            let level = (decibels - Self.floorDecibels) / (Self.ceilingDecibels - Self.floorDecibels)
            // Unexpected sample content can turn the math non-finite, and a
            // non-finite band would crash layout as a NaN view height.
            let bounded = level.isFinite ? min(1, max(0, level)) : 0
            // Fast attack with slow decay reads as natural motion.
            bands[index] = max(bounded, bands[index] * 0.75)
        }
    }
}
