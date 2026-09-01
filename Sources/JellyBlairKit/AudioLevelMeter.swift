import Accelerate
import AVFoundation
import Foundation
import MediaToolbox

/// Measures per-band levels of the playing audio through an MTAudioProcessingTap.
/// The tap writes on the audio render thread; the UI reads at frame rate.
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

    private let lock = NSLock()
    private var bands = [Float](repeating: 0, count: AudioLevelMeter.bandCount)
    private let fftSetup: FFTSetup

    init() {
        fftSetup = vDSP_create_fftsetup(Self.fftSizeLog2, FFTRadix(kFFTRadix2))!
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    public func currentBands() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return bands
    }

    func reset() {
        lock.lock()
        bands = [Float](repeating: 0, count: Self.bandCount)
        lock.unlock()
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
            prepare: nil,
            unprepare: nil,
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
                guard status == noErr else { return }
                let meter = Unmanaged<AudioLevelMeter>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                meter.measure(bufferList: bufferListInOut, frameCount: Int(numberFramesOut.pointee))
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

    // MARK: - Measurement

    private func measure(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard let first = buffers.first(where: { $0.mData != nil }) else { return }
        let sampleCapacity = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        let count = min(frameCount, sampleCapacity, Self.fftSize)
        guard count >= 64 else { return }
        let samples = first.mData!.assumingMemoryBound(to: Float.self)
        computeBands(samples: samples, count: count)
    }

    private func computeBands(samples: UnsafePointer<Float>, count: Int) {
        var padded = [Float](repeating: 0, count: Self.fftSize)
        padded.withUnsafeMutableBufferPointer { destination in
            destination.baseAddress!.update(from: samples, count: count)
        }
        var real = [Float](repeating: 0, count: Self.fftSize / 2)
        var imaginary = [Float](repeating: 0, count: Self.fftSize / 2)
        var magnitudes = [Float](repeating: 0, count: Self.fftSize / 2)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                padded.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(Self.fftSize / 2))
                }
                vDSP_fft_zrip(fftSetup, &split, 1, Self.fftSizeLog2, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(Self.fftSize / 2))
            }
        }
        updateBands(magnitudes: magnitudes)
    }

    private func updateBands(magnitudes: [Float]) {
        var newBands = [Float](repeating: 0, count: Self.bandCount)
        for (index, range) in Self.bandBinRanges.enumerated() {
            let meanPower = magnitudes[range].reduce(0, +) / Float(range.count)
            let amplitude = sqrt(meanPower) / Float(Self.fftSize)
            let decibels = 20 * log10(max(amplitude, 1e-7))
            let level = (decibels - Self.floorDecibels) / (Self.ceilingDecibels - Self.floorDecibels)
            newBands[index] = min(1, max(0, level))
        }
        lock.lock()
        for index in 0..<Self.bandCount {
            // Fast attack with slow decay reads as natural motion.
            bands[index] = max(newBands[index], bands[index] * 0.75)
        }
        lock.unlock()
    }
}
