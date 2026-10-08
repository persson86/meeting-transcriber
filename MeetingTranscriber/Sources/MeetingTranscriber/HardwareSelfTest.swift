#if MT_HARDWARE_SELFTEST
import AVFoundation
import Foundation

/// Autoteste de hardware, compilado só com `-DMT_HARDWARE_SELFTEST` (nunca no
/// build de release). Roda dentro do bundle assinado para herdar as permissões
/// de microfone e gravação de tela do app; não cria AppState, sessão nem UI.
///
///   open -W -n MeetingTranscriber.app --args --hardware-selftest <pasta> <segundos> [<python> <script>]
enum HardwareSelfTest {
    static func runIfRequested() {
        let args = CommandLine.arguments
        // Processo separado fazendo papel de app de call (voice processing).
        if let index = args.firstIndex(of: "--call-process"), index + 1 < args.count {
            let seconds = Double(args[index + 1]) ?? 20
            let engine = AVAudioEngine()
            do {
                // E0 (07/out): --call-device builtin fixa o processo de "call" no embutido;
                // sem a flag ele usa a entrada padrão (o fone, quando BT é padrão).
                if let di = args.firstIndex(of: "--call-device"), di + 1 < args.count, args[di + 1] == "builtin",
                   let builtIn = MicInputDevices.all().first(where: { $0.isBuiltIn }), let unit = engine.inputNode.audioUnit {
                    var id = builtIn.id
                    AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                                         UInt32(MemoryLayout<AudioDeviceID>.size))
                }
                try engine.inputNode.setVoiceProcessingEnabled(true)
                engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { _, _ in }
                try engine.start()
            } catch {
                exit(3)
            }
            Thread.sleep(forTimeInterval: seconds)
            engine.stop()
            exit(0)
        }
        guard let index = args.firstIndex(of: "--hardware-selftest"), index + 2 < args.count else { return }
        let directory = URL(fileURLWithPath: args[index + 1])
        let seconds = Double(args[index + 2]) ?? 60
        let python = index + 3 < args.count && !args[index + 3].hasPrefix("--") ? args[index + 3] : nil
        let script = index + 4 < args.count && !args[index + 4].hasPrefix("--") ? args[index + 4] : nil
        // --simulate-call <início> <fim>: outro engine abre o mesmo mic com voice
        // processing, como apps de call fazem ao entrar numa reunião.
        if let callIndex = args.firstIndex(of: "--simulate-call"), callIndex + 2 < args.count,
           let start = Double(args[callIndex + 1]), let end = Double(args[callIndex + 2]) {
            callWindow = (start, end)
        }
        if let probeIndex = args.firstIndex(of: "--probe-at"), probeIndex + 1 < args.count {
            probeAt = Double(args[probeIndex + 1])
        }
        if let probeIndex = args.firstIndex(of: "--probe-session-at"), probeIndex + 1 < args.count {
            probeSessionAt = Double(args[probeIndex + 1])
        }
        if let probeIndex = args.firstIndex(of: "--probe-builtin-at"), probeIndex + 1 < args.count {
            probeBuiltInAt = Double(args[probeIndex + 1])
        }

        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await run(directory: directory, seconds: seconds, python: python, script: script)
            done.signal()
        }
        done.wait()
        exit(0)
    }

    private static var callWindow: (Double, Double)?
    private static var probeAt: Double?
    private static var probeSessionAt: Double?
    private static var probeBuiltInAt: Double?

    private final class SessionProbe: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
        let lock = NSLock()
        var buffers = 0, nonZeroBytes = 0, totalBytes = 0
        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
                  let pointer else { return }
            var nonZero = 0
            for index in 0..<length where pointer[index] != 0 { nonZero += 1 }
            lock.withLock { buffers += 1; nonZeroBytes += nonZero; totalBytes += length }
        }
    }

    /// Sonda: AVCaptureSession (pipeline de captura do CoreMedia) recebe áudio durante a call?
    private static func probeCaptureSession(note: (String) -> Void) {
        guard let device = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device) else { note("PROBE-SESSION no device"); return }
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        let probe = SessionProbe()
        output.setSampleBufferDelegate(probe, queue: DispatchQueue(label: "probe.session"))
        guard session.canAddInput(input), session.canAddOutput(output) else { note("PROBE-SESSION cannot add"); return }
        session.addInput(input); session.addOutput(output)
        session.startRunning()
        Thread.sleep(forTimeInterval: 4)
        session.stopRunning()
        probe.lock.withLock {
            note("PROBE-SESSION device=\(device.localizedName) buffers=\(probe.buffers) nonZeroBytes=\(probe.nonZeroBytes)/\(probe.totalBytes)")
        }
    }

    /// Sonda (07/out): o dispositivo embutido entrega IO por caminhos que não passam
    /// pelo AVAudioEngine — IOProc direto no HAL e AVCaptureSession com o
    /// dispositivo explícito — enquanto a entrada padrão é o fone BT?
    private static func nominalSampleRate(_ id: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = 0.0; var size = UInt32(MemoryLayout<Double>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value); return value
    }

    private static func setSystemDefaultInput(_ id: AudioDeviceID) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = id
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &value)
    }

    private static func probeBuiltInRaw(note: (String) -> Void) {
        guard let dev = MicInputDevices.all().first(where: { $0.isBuiltIn }) else { note("PROBE-RAW: sem embutido"); return }
        let lock = NSLock()
        var callbacks = 0, nonZero = 0, total = 0
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, dev.id, nil) { _, inData, _, _, _ in
            var nz = 0, t = 0
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            for buf in abl {
                let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
                if let p = buf.mData?.assumingMemoryBound(to: Float.self) {
                    for i in 0..<n where p[i] != 0 { nz += 1 }
                    t += n
                }
            }
            lock.withLock { callbacks += 1; nonZero += nz; total += t }
        }
        guard status == noErr, let procID else { note("PROBE-RAW: create falhou \(status)"); return }
        let started = AudioDeviceStart(dev.id, procID)
        note("PROBE-RAW: start status=\(started) device=\(dev.label) id=\(dev.id)")
        Thread.sleep(forTimeInterval: 4)
        AudioDeviceStop(dev.id, procID)
        AudioDeviceDestroyIOProcID(dev.id, procID)
        lock.withLock { note("PROBE-RAW IOProc embutido: callbacks=\(callbacks) nonZeroSamples=\(nonZero)/\(total)") }
    }

    private static func probeBuiltInCaptureSession(note: (String) -> Void) {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone], mediaType: .audio, position: .unspecified)
        note("PROBE-SESSION-BI devices: \(discovery.devices.map { "\($0.localizedName)|\($0.uniqueID)" })")
        guard let device = discovery.devices.first(where: { $0.uniqueID.contains("BuiltIn") || $0.localizedName.contains("MacBook") }),
              let input = try? AVCaptureDeviceInput(device: device) else { note("PROBE-SESSION-BI: sem embutido"); return }
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        let probe = SessionProbe()
        output.setSampleBufferDelegate(probe, queue: DispatchQueue(label: "probe.session.bi"))
        guard session.canAddInput(input), session.canAddOutput(output) else { note("PROBE-SESSION-BI cannot add"); return }
        session.addInput(input); session.addOutput(output)
        session.startRunning()
        Thread.sleep(forTimeInterval: 4)
        session.stopRunning()
        probe.lock.withLock {
            note("PROBE-SESSION-BI device=\(device.localizedName) buffers=\(probe.buffers) nonZeroBytes=\(probe.nonZeroBytes)/\(probe.totalBytes)")
        }
    }

    /// Sonda: um AVAudioEngine novo, criado no meio da "call", recebe áudio real?
    private static func probeFreshEngine(note: (String) -> Void) {
        let engine = AVAudioEngine()
        let lock = NSLock()
        var buffers = 0, nonZero = 0, total = 0
        let format = engine.inputNode.outputFormat(forBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            var count = 0
            for index in 0..<Int(buffer.frameLength) where channel[index] != 0 { count += 1 }
            lock.withLock { buffers += 1; nonZero += count; total += Int(buffer.frameLength) }
        }
        do { try engine.start() } catch { note("PROBE start failed: \(error.localizedDescription)"); return }
        Thread.sleep(forTimeInterval: 4)
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        lock.withLock { note("PROBE fresh engine during call: format=\(format) buffers=\(buffers) nonZeroSamples=\(nonZero)/\(total)") }
    }

    private static func run(directory: URL, seconds: Double, python: String?, script: String?) async {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("selftest.log")
        fm.createFile(atPath: log.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: log)
        func note(_ line: String) {
            let stamp = ISO8601DateFormatter().string(from: Date())
            handle?.write(Data("\(stamp) \(line)\n".utf8))
        }

        // --mic-policy builtin|default: compara a política nova com a antiga.
        let policyArg = CommandLine.arguments.firstIndex(of: "--mic-policy").flatMap { index in
            index + 1 < CommandLine.arguments.count ? MicInputPolicy(rawValue: CommandLine.arguments[index + 1]) : nil
        }
        // --set-default-input builtin (07/out): aposta de fixar a ENTRADA PADRÃO do
        // sistema no embutido durante a gravação e restaurar no fim.
        var restoreDefault: MicInputDevice?
        if let i = CommandLine.arguments.firstIndex(of: "--set-default-input"), i + 1 < CommandLine.arguments.count,
           CommandLine.arguments[i + 1] == "builtin", let builtIn = MicInputDevices.all().first(where: { $0.isBuiltIn }) {
            let previous = MicInputDevices.systemDefault()
            let status = setSystemDefaultInput(builtIn.id)
            note("DEFAULT-INPUT: \(previous?.label ?? "?") -> \(builtIn.label) status=\(status)")
            if status == noErr, let previous, previous.id != builtIn.id { restoreDefault = previous }
        }
        defer {
            if let previous = restoreDefault, MicInputDevices.find(uid: previous.uid) != nil {
                let status = setSystemDefaultInput(previous.id)
                note("DEFAULT-INPUT restaurado: \(previous.label) status=\(status)")
            }
        }
        // --backend engine|raw (07/out): A/B do IOProc direto contra o AVAudioEngine.
        let backendArg = CommandLine.arguments.firstIndex(of: "--backend").flatMap { index in
            index + 1 < CommandLine.arguments.count ? MicRecorder.CaptureBackend(rawValue: CommandLine.arguments[index + 1]) : nil
        }
        let mic = MicRecorder(
            stagingDirectory: directory,
            stagingFileName: "mic.inprogress.wav",
            preserveOnDeinit: true,
            policy: policyArg ?? AppConfig.micInputPolicy,
            captureBackend: backendArg ?? AppConfig.micCaptureBackend
        )
        let system = SystemAudioRecorder(stagingDirectory: directory, stagingFileName: "system.inprogress.wav", preserveOnDeinit: true)
        let startedAt = Date()
        do {
            try mic.start()
            note("mic started")
            try await system.start()
            note("system started")
        } catch {
            note("START FAILED: \(error.localizedDescription)")
            return
        }

        let deadline = Date().addingTimeInterval(seconds)
        var callEngine: AVAudioEngine?
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            note("mic \(String(describing: mic.health))")
            note("DEV default=\(MicInputDevices.systemDefault()?.label ?? "?") rates=\(MicInputDevices.all().map { "\($0.name.prefix(12))@\(Int(nominalSampleRate($0.id)))" })")
            if let at = probeAt, Date().timeIntervalSince(startedAt) >= at {
                probeAt = nil
                probeFreshEngine(note: note)
            }
            if let at = probeSessionAt, Date().timeIntervalSince(startedAt) >= at {
                probeSessionAt = nil
                probeCaptureSession(note: note)
            }
            if let at = probeBuiltInAt, Date().timeIntervalSince(startedAt) >= at {
                probeBuiltInAt = nil
                probeBuiltInRaw(note: note)
                probeBuiltInCaptureSession(note: note)
            }
            if let (callStart, callEnd) = callWindow {
                let elapsed = Date().timeIntervalSince(startedAt)
                if callEngine == nil, elapsed >= callStart, elapsed < callEnd {
                    let engine = AVAudioEngine()
                    do {
                        try engine.inputNode.setVoiceProcessingEnabled(true)
                        let format = engine.inputNode.outputFormat(forBus: 0)
                        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { _, _ in }
                        try engine.start()
                        callEngine = engine
                        note("CALL SIM started (voice processing) format=\(format)")
                    } catch {
                        note("CALL SIM failed: \(error.localizedDescription)")
                        callWindow = nil
                    }
                } else if let engine = callEngine, elapsed >= callEnd {
                    engine.stop()
                    engine.inputNode.removeTap(onBus: 0)
                    try? engine.inputNode.setVoiceProcessingEnabled(false)
                    callEngine = nil
                    callWindow = nil
                    note("CALL SIM stopped")
                }
            }
        }

        let micURL = directory.appendingPathComponent("mic.wav")
        let systemURL = directory.appendingPathComponent("system.wav")
        do { try mic.stop(saveTo: micURL); note("mic saved") } catch { note("MIC STOP ERROR: \(error.localizedDescription)") }
        do { try await system.stop(saveTo: systemURL); note("system saved") } catch { note("SYSTEM STOP ERROR: \(error.localizedDescription)") }
        note("final mic \(String(describing: mic.health))")
        for event in mic.health.events { note("mic event \(event)") }
        note("final system \(String(describing: system.health))")
        // Mesma conta de AppState.computeOffsetMs, sem depender do MainActor
        // (a thread principal está bloqueada durante o autoteste).
        var offset = 0.0
        if let micTime = mic.firstBufferTime, let sysTime = system.firstBufferTime {
            var info = mach_timebase_info_data_t()
            mach_timebase_info(&info)
            let nsPerTick = Double(info.numer) / Double(info.denom)
            offset = (Double(sysTime) - Double(micTime)) * nsPerTick / 1_000_000.0
        }
        note("sysOffsetMs \(offset)")

        guard let python, let script else { return }
        let runner = TranscriptionRunner(python: python, script: script)
        do {
            let output = try await runner.run(
                micURL: fm.fileExists(atPath: micURL.path) ? micURL : nil,
                systemURL: fm.fileExists(atPath: systemURL.path) ? systemURL : nil,
                title: "Autoteste de hardware",
                language: "auto",
                sysOffsetMs: offset,
                outputDir: directory.appendingPathComponent("out"),
                sessionID: UUID(),
                captureIntegrity: .complete,
                recordedAt: startedAt
            )
            note("transcription ok: \(output.path)")
        } catch {
            note("TRANSCRIPTION FAILED: \(error.localizedDescription)")
        }
    }
}
#endif
