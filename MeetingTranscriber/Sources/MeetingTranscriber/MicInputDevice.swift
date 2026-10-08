import CoreAudio
import Foundation

/// Dispositivo de entrada visto pelo HAL. O UID é estável entre reconexões; o
/// `AudioDeviceID` não é (muda quando um headset Bluetooth reconecta).
struct MicInputDevice: Equatable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: String

    var isBuiltIn: Bool { transport == "built-in" }
    var label: String { "\(name) (\(transport))" }
}

/// Qual microfone a gravação usa. `builtIn` fixa o microfone do Mac no início e
/// ignora mudanças do dispositivo padrão do sistema: um headset que conecta no
/// meio da reunião não sequestra a captura (sessão de 01/out/2026). `systemDefault`
/// mantém o comportamento anterior, seguindo o padrão do macOS.
enum MicInputPolicy: String, Sendable {
    case builtIn = "builtin"
    case systemDefault = "default"

    /// Escolhe o dispositivo para fixar. Sem microfone embutido (Mac fechado com
    /// monitor externo, por exemplo), cai no padrão do sistema.
    func select(from devices: [MicInputDevice], systemDefault: MicInputDevice?) -> MicInputDevice? {
        switch self {
        case .builtIn:
            return devices.first(where: \.isBuiltIn) ?? systemDefault
        case .systemDefault:
            return systemDefault
        }
    }
    // v1.7: sem troca automática para o padrão do sistema quando o embutido fica
    // sem sinal. A troca levava a captura para o headset Bluetooth (HFP), com
    // dezenas de rearmes e eco. Se o embutido some de fato, `resolveDevice`
    // escolhe de novo; fora disso, o alerta pede o botão "Reiniciar microfone".
}

enum MicInputDevices {
    static func all() -> [MicInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.compactMap { id in inputChannelCount(id) > 0 ? device(id) : nil }
    }

    /// Troca a entrada padrão do sistema (kAudioHardwarePropertyDefaultInputDevice).
    static func setSystemDefault(_ id: AudioDeviceID) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = id
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &value)
    }

    static func systemDefault() -> MicInputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return device(id)
    }

    /// Reencontra pelo UID, porque o ID numérico muda quando o dispositivo some e volta.
    static func find(uid: String) -> MicInputDevice? {
        all().first { $0.uid == uid }
    }

    static func device(_ id: AudioDeviceID) -> MicInputDevice? {
        guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let name = stringProperty(id, kAudioObjectPropertyName) ?? uid
        return MicInputDevice(id: id, uid: uid, name: name, transport: transportName(transportType(id)))
    }

    static func transportName(_ transport: UInt32) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless:
            return "continuity"
        case 0: return "unknown"
        default: return "other"
        }
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
