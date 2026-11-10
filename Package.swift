// swift-tools-version:5.9
// Touch SD: macOS app for the Touch SD fingerprint card (fingerprint capture, enrolment, unlock,
// slide input, firmware update).  OpenCV comes from vendor/opencv, built by
// scripts/build_opencv.sh; scripts/build_app.sh makes the universal .app.
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let cv = "\(root)/vendor/opencv"

let package = Package(
    name: "SDFinger",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CvBridge",
            path: "Sources/CvBridge",
            cxxSettings: [
                .unsafeFlags(["-I\(cv)/include/opencv5", "-std=c++17", "-fobjc-arc"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L\(cv)/lib"]),
                // order matters for static libraries: users before what they use
                .linkedLibrary("opencv_video"),
                .linkedLibrary("opencv_features"),
                .linkedLibrary("opencv_geometry"),
                .linkedLibrary("opencv_flann"),
                .linkedLibrary("opencv_imgproc"),
                .linkedLibrary("opencv_core"),
                .linkedLibrary("kleidicv_hal"),
                .linkedLibrary("kleidicv_thread"),
                .linkedLibrary("kleidicv"),
                .linkedLibrary("tegra_hal"),
                .linkedLibrary("zlib"),
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
            ]
        ),
        .target(name: "FingerCore", dependencies: ["CvBridge"], path: "Sources/FingerCore"),
        .target(name: "FingerUI", dependencies: ["FingerCore"], path: "Sources/FingerUI"),
        // the app
        .executableTarget(name: "SDFinger", dependencies: ["FingerCore", "FingerUI"], path: "Sources/SDFinger"),
        // scripts ask for a press (not "sdfinger": the file system does not tell it from SDFinger)
        .executableTarget(name: "fingerconfirm", path: "Sources/fingerconfirm"),
    ],
    swiftLanguageVersions: [.v5],
    cxxLanguageStandard: .cxx17
)
