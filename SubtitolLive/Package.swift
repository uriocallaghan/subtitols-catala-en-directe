// swift-tools-version: 5.9

import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let runtimeDirectory = packageDirectory
    .appendingPathComponent("Vendor/Runtime")
    .path

let package = Package(
    name: "SubtitolLive",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "SubtitolLive", targets: ["SubtitolLive"]),
        .executable(name: "SubtitolLatencyHarness", targets: ["SubtitolLatencyHarness"]),
        .executable(name: "SubtitolEngineIntegrationTests", targets: ["SubtitolEngineIntegrationTests"]),
    ],
    targets: [
        .target(
            name: "SubtitolCore",
            path: "Sources/SubtitolCore"
        ),
        .target(
            name: "CNemoSpeech",
            path: "Sources/CNemoSpeech",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags(["-L", runtimeDirectory]),
                .linkedLibrary("nemo_speech_asr_c"),
            ]
        ),
        .target(
            name: "SubtitolEngine",
            dependencies: ["CNemoSpeech", "SubtitolCore"],
            path: "Sources/SubtitolEngine"
        ),
        .target(
            name: "SubtitolPunctuation",
            dependencies: ["SubtitolCore"],
            path: "Sources/SubtitolPunctuation",
            linkerSettings: [.linkedFramework("CoreML")]
        ),
        .target(
            name: "SubtitolSpeakers",
            dependencies: ["SubtitolCore", "SubtitolPunctuation"],
            path: "Sources/SubtitolSpeakers",
            linkerSettings: [.linkedFramework("CoreML")]
        ),
        .executableTarget(
            name: "SubtitolLive",
            dependencies: ["SubtitolEngine", "SubtitolCore", "SubtitolPunctuation", "SubtitolSpeakers"],
            path: "Sources/SubtitolLive",
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", runtimeDirectory,
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ]),
            ]
        ),
        .executableTarget(
            name: "SubtitolLiveTests",
            dependencies: ["SubtitolCore"],
            path: "Tests/SubtitolLiveTests"
        ),
        .executableTarget(
            name: "SubtitolPunctuationCheck",
            dependencies: ["SubtitolCore", "SubtitolPunctuation"],
            path: "Tests/SubtitolPunctuationCheck"
        ),
        .executableTarget(
            name: "SubtitolLatencyHarness",
            dependencies: ["SubtitolEngine", "SubtitolCore", "SubtitolPunctuation", "SubtitolSpeakers"],
            path: "Sources/SubtitolLatencyHarness",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", runtimeDirectory,
                ]),
            ]
        ),
        .executableTarget(
            name: "SubtitolEngineIntegrationTests",
            dependencies: ["SubtitolEngine", "SubtitolCore"],
            path: "Tests/SubtitolEngineIntegrationTests",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", runtimeDirectory,
                ]),
            ]
        ),
    ]
)
