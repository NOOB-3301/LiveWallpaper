import Accelerate
import CoreAudio
import Foundation

// Audio response: what the Mac is playing, as a spectrum for scenes that move with music. A Core
// Audio process tap (macOS 14.2+) captures the system output; the first use asks the user for
// permission (NSAudioCaptureUsageDescription). Nothing is recorded or kept, only band levels.

enum AudioTapError: Error {
    case status(String, OSStatus)
}

/// Captures system audio and reports 64 band levels (0...1, low to high) per channel, about 30
/// times a second, on its own queue.
@available(macOS 14.2, *)
final class SystemAudioTap: @unchecked Sendable {
    var onSpectrum: (([Float], [Float]) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "PaperFlow.audio-tap", qos: .utility)
    private var left = SpectrumAnalyzer()
    private var right = SpectrumAnalyzer()

    func start() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        try check("create tap", AudioHardwareCreateProcessTap(description, &tapID))

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        try check("tap format", AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format))
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            throw AudioTapError.status("tap format is not float PCM", -1)
        }
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let channels = Int(format.mChannelsPerFrame)

        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "PaperFlow audio response",
            kAudioAggregateDeviceUIDKey: "PaperFlow-\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        if let output = Self.defaultOutputUID() {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = output
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: output]]
        }
        try check("create device", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))

        try check("io proc", AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
            [weak self] _, input, _, _, _ in
            self?.consume(input, interleaved: interleaved, channels: channels)
        })
        try check("start", AudioDeviceStart(aggregateID, procID))
    }

    func stop() {
        onSpectrum = nil
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    /// Runs on `queue`.
    private func consume(_ input: UnsafePointer<AudioBufferList>, interleaved: Bool, channels: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let data = first.mData, channels > 0 else { return }
        if interleaved {
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let samples = data.assumingMemoryBound(to: Float.self)
            for i in 0..<frames {
                left.push(samples[i * channels])
                right.push(samples[i * channels + min(1, channels - 1)])
                publishIfReady()
            }
        } else {
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let l = data.assumingMemoryBound(to: Float.self)
            let r = (buffers.count > 1 ? buffers[1].mData : data)?.assumingMemoryBound(to: Float.self) ?? l
            for i in 0..<frames {
                left.push(l[i])
                right.push(r[i])
                publishIfReady()
            }
        }
    }

    /// One spectrum per full analysis block: about 30 a second at 48 kHz.
    private func publishIfReady() {
        guard left.pending == SpectrumAnalyzer.window else { return }
        onSpectrum?(left.bands(), right.bands())
    }

    private static func defaultOutputUID() -> String? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return nil }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    private func check(_ what: String, _ status: OSStatus) throws {
        guard status == noErr else { throw AudioTapError.status(what, status) }
    }
}

/// One channel's spectrum for audio response. Each block of 1600 samples (about 33 ms at 48 kHz) is
/// Hann-windowed, zero-padded to a 2048-point FFT, and summed into 64 log-spaced bands. A band's
/// level is its mean amplitude in dB, mapped from -80 dB to 0 dB onto 0...1. Silence reads as zero.
struct SpectrumAnalyzer {
    static let window = 1600
    private static let fftSize = 2048
    private static let log2n = vDSP_Length(11)
    private static let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    private static let hann = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                                          count: window, isHalfWindow: false)
    /// Scales the FFT magnitude to the amplitude of a sine of that frequency. vDSP's real transform
    /// returns twice the true value, so this is 1 / (window sum) rather than 2 / (window sum).
    private static let gain = 1 / hann.reduce(0, +)
    /// Bin edges of the 64 bands: logarithmic from bin 1 up to the Nyquist bin.
    private static let edges: [Int] = {
        var edges = [1]
        for band in 1...64 {
            let edge = Int(pow(1023.0, Double(band) / 64).rounded(.down))
            edges.append(max(edge, edges[band - 1] + 1))
        }
        return edges
    }()

    private var block: [Float] = []

    var pending: Int { block.count }

    mutating func push(_ sample: Float) {
        block.append(sample.isFinite ? min(max(sample, -1), 1) : 0)
    }

    /// Analyses the pending block and clears it. Call once `pending` reaches `window`.
    mutating func bands() -> [Float] {
        defer { block.removeAll(keepingCapacity: true) }
        let n = Self.fftSize, half = n / 2
        var windowed = [Float](repeating: 0, count: n)
        for i in 0..<min(block.count, Self.window) {
            windowed[i] = block[i] * Self.hann[i]
        }
        // Real FFT input is packed as even samples in realp and odd samples in imagp.
        var realp = (0..<half).map { windowed[$0 * 2] }
        var imagp = (0..<half).map { windowed[$0 * 2 + 1] }
        var magnitudes = [Float](repeating: 0, count: half)
        realp.withUnsafeMutableBufferPointer { re in
            imagp.withUnsafeMutableBufferPointer { im in
                magnitudes.withUnsafeMutableBufferPointer { out in
                    var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                    vDSP_fft_zrip(Self.setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, out.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }
        return (0..<64).map { band in
            let lo = Self.edges[band], hi = Self.edges[band + 1]
            var sum: Float = 0
            for bin in lo..<hi {
                sum += magnitudes[bin]
            }
            return Self.level(sum / Float(hi - lo) * Self.gain)
        }
    }

    /// Amplitude to a 0...1 level: -60 dB to -10 dB, squared. Scenes expect a peaked spectrum (loud
    /// bands high, quiet bands near 0); a plain wide dB range lifted every band of ordinary music to
    /// about half, which drew audio waveforms as solid flat bands.
    private static func level(_ amplitude: Float) -> Float {
        let decibels = 20 * log10(max(amplitude, 1e-6))
        let x = min(max((decibels + 60) / 50, 0), 1)
        return x * x
    }
}
