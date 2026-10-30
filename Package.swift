// swift-tools-version:5.9
// Eigener Filterlisten-Konverter für Still (ersetzt perspektivisch die GPL-lizenzierte SafariConverterLib)
// und das Prüfprogramm `still-check`, das Safari-Blocker mit echtem WebKit testet.
import PackageDescription

let package = Package(
    name: "StillFilterKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "StillFilterKit", targets: ["StillFilterKit"]),
        .executable(name: "still-check", targets: ["still-check"]),
    ],
    targets: [
        .target(name: "StillFilterKit"),
        .executableTarget(name: "still-check", dependencies: ["StillFilterKit"]),
        .testTarget(name: "StillFilterKitTests", dependencies: ["StillFilterKit"]),
    ]
)
