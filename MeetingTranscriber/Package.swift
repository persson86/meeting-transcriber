// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeetingTranscriber",
    platforms: [.macOS(.v13)],
    targets: [
        // Shim ObjC: único lugar onde o AVAudioEngine pode levantar NSException.
        // Converte a exceção em NSError antes de voltar ao Swift.
        .target(
            name: "ObjCExceptionCatcher",
            path: "Sources/ObjCExceptionCatcher",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio")
            ]
        ),
        .executableTarget(
            name: "MeetingTranscriber",
            dependencies: ["ObjCExceptionCatcher"],
            path: "Sources/MeetingTranscriber",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=minimal"])
            ]
        ),
        .testTarget(
            name: "MeetingTranscriberTests",
            dependencies: ["MeetingTranscriber", "ObjCExceptionCatcher"],
            path: "Tests/MeetingTranscriberTests"
        )
    ]
)
