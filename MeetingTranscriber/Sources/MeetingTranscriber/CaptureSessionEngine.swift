import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import ObjCExceptionCatcher

/// Fallback de captura do mic: AVCaptureSession + AVCaptureAudioDataOutput. Entra quando
/// o AVAudioEngine reconstruído segue sem buffers (ex.: voice processing de outro app
/// prende o IO unit) e entrega ao mesmo pipeline do tap (geração, conversor, gap filler).
final class CaptureSessionEngine: NSObject, MicCaptureEngine, AVCaptureAudioDataOutputSampleBufferDelegate {
    static let backendIdentifier = "captureSession"

    private let shim = MTCaptureSessionShim()
    private let output = AVCaptureAudioDataOutput()
    private let sampleQueue = DispatchQueue(
        label: "MeetingTranscriber.CaptureSessionEngine.samples",
        qos: .userInitiated
    )
    private let device: AVCaptureDevice?
    private let tapLock = NSLock()
    private var tapBlock: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var observer: NSObjectProtocol?
    private var configured = false

    override init() {
        device = AVCaptureDevice.default(for: .audio)
        super.init()
    }

    var backendName: String { Self.backendIdentifier }

    var isRunning: Bool { shim.isRunning }

    var inputDevice: MicInputDevice? {
        guard let device else { return nil }
        return MicInputDevice(
            name: device.localizedName,
            uid: device.uniqueID,
            transport: Self.transportName(device.transportType)
        )
    }

    func installInputTap(
        bufferSize: AVAudioFrameCount,
        block: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws {
        tapLock.withLock { tapBlock = block }
        output.setSampleBufferDelegate(self, queue: sampleQueue)
    }

    func removeInputTap() throws {
        tapLock.withLock { tapBlock = nil }
        output.setSampleBufferDelegate(nil, queue: nil)
    }

    func prepare() throws {
        guard !configured else { return }
        guard let device else {
            throw NSError(domain: "CaptureSessionEngine", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Nenhum dispositivo de áudio disponível para o AVCaptureSession."])
        }
        try shim.configure(with: device, output: output)
        configured = true
    }

    func start() throws {
        try prepare()
        try shim.startRunning()
    }

    func stop() throws {
        try shim.stopRunning()
    }

    func setConfigurationChangeHandler(_ handler: (() -> Void)?) {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        guard let handler else { return }
        // Erro de runtime da sessão conta como mudança: o recorder confere buffers em 500 ms.
        observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVCaptureSessionRuntimeError,
            object: shim.session,
            queue: nil
        ) { _ in handler() }
    }

    deinit {
        setConfigurationChangeHandler(nil)
    }

    // MARK: AVCaptureAudioDataOutputSampleBufferDelegate (sampleQueue)

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let block = tapLock.withLock({ tapBlock }) else { return }
        guard let pcm = Self.makePCMBuffer(from: sampleBuffer) else { return }
        let time: AVAudioTime
        if let ticks = Self.hostTicks(
            forPresentationTime: sampleBuffer.presentationTimeStamp,
            sessionClock: shim.session.synchronizationClock
        ) {
            time = AVAudioTime(hostTime: ticks)
        } else {
            time = AVAudioTime(sampleTime: 0, atRate: pcm.format.sampleRate)
        }
        block(pcm, time)
    }

    /// CMSampleBuffer PCM → AVAudioPCMBuffer no formato do próprio buffer.
    static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription else { return nil }
        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frameCount > 0 else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount), into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }

    /// PTS da sessão → host time em unidades de mach. Com relógio de sessão presente,
    /// converte para o relógio de host (host→host é identidade).
    static func hostTicks(forPresentationTime pts: CMTime, sessionClock: CMClock?) -> UInt64? {
        guard pts.isValid else { return nil }
        var hostTime = pts
        if let sessionClock {
            hostTime = CMSyncConvertTime(pts, from: sessionClock, to: CMClockGetHostTimeClock())
        }
        guard hostTime.isValid else { return nil }
        return CMClockConvertHostTimeToSystemUnits(hostTime)
    }

    static func transportName(_ transportType: Int32) -> String? {
        let code = UInt32(bitPattern: transportType)
        switch code {
        case 0: return nil
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeHDMI: return "hdmi"
        case kAudioDeviceTransportTypeDisplayPort: return "displayport"
        case kAudioDeviceTransportTypeThunderbolt: return "thunderbolt"
        case kAudioDeviceTransportTypeAirPlay: return "airplay"
        default: return String(format: "0x%08X", code)
        }
    }
}
