// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeetingTranscriber",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MeetingTranscriber",
            path: "Sources/MeetingTranscriber",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=minimal"])
            ]
        ),
        .testTarget(
            name: "MeetingTranscriberTests",
            dependencies: ["MeetingTranscriber"],
            path: "Tests/MeetingTranscriberTests"
        )
    ]
)
