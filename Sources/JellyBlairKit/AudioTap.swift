import AVFoundation
import Foundation
import MediaToolbox

/// Owns the processing tap on the playing item and runs each buffer through
/// the limiter and then the meter on the audio render thread, so the bars
/// show what plays. Only 32-bit float PCM can be read, so any other format
/// passes through untouched.
final class AudioTap {
    private let limiter: PeakLimiter
    private let meter: AudioLevelMeter

    /// Guards the format flag, which the tap's prepare and unprepare
    /// callbacks write and the render thread reads.
    private let lock = NSLock()
    private var formatIsFloat32 = false

    init(limiter: PeakLimiter, meter: AudioLevelMeter) {
        self.limiter = limiter
        self.meter = meter
    }

    /// Builds an audio mix whose processing tap feeds this object.
    func makeAudioMix(for track: AVAssetTrack) -> AVAudioMix? {
        // The tap retains this object and releases it in finalize, so the
        // audio thread can never call into a deallocated one.
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque()),
            init: { _, clientInfo, tapStorageOut in
                tapStorageOut.pointee = clientInfo!
            },
            finalize: { tap in
                Unmanaged<AudioTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                AudioTap.owner(of: tap).prepare(format: format.pointee)
            },
            unprepare: { tap in
                AudioTap.owner(of: tap).unprepare()
            },
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
                guard status == noErr else { return }
                AudioTap.owner(of: tap).process(bufferList: bufferListInOut, frameCount: Int(numberFramesOut.pointee))
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

    private static func owner(of tap: MTAudioProcessingTap) -> AudioTap {
        Unmanaged<AudioTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    }

    private func prepare(format: AudioStreamBasicDescription) {
        let isFloat32 = format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mBitsPerChannel == 32
        lock.lock()
        formatIsFloat32 = isFloat32
        lock.unlock()
        let sampleRate = Float(format.mSampleRate)
        limiter.setSampleRate(sampleRate)
        meter.setSampleRate(sampleRate)
    }

    private func unprepare() {
        lock.lock()
        formatIsFloat32 = false
        lock.unlock()
    }

    private func process(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        lock.lock()
        let readable = formatIsFloat32
        lock.unlock()
        guard readable else { return }
        limiter.process(bufferList: bufferList, frameCount: frameCount)
        meter.capture(bufferList: bufferList, frameCount: frameCount)
    }
}
