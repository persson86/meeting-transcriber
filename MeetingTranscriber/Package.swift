// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeetingTranscriber",
    platforms: [.macOS(.v13)],
    targets: [
        // Shim ObjC: converte NSException (ex.: do AVAudioEngine no rearme do mic)
        // em NSError antes de voltar ao Swift, que não captura exceções ObjC.
        .target(
            name: "ObjCExceptionCatcher",
            path: "Sources/ObjCExceptionCatcher",
            publicHeadersPath: "include"
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
