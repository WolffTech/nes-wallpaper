// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NESWallpaper",
    platforms: [.macOS(.v14)],
    targets: [
        // FCEUX core (vendored, see vendor/VENDOR.md) plus a C shim.
        .target(
            name: "CFCEUX",
            path: "Sources/CFCEUX",
            exclude: [
                "fceux/fir",
                "fceux/palettes/conv.cpp",
                "fceux/ops.inc",
                "fceux/pputile.inc",
            ],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("fceux"),
                .define("HAVE_ASPRINTF"),
                .define("LSB_FIRST"),
                .unsafeFlags([
                    "-Wno-everything",
                ]),
            ],
            linkerSettings: [
                .linkedLibrary("z"),
            ]
        ),
        // CLI harness: run a ROM (+ optional FM2) headless, dump PNG frames.
        .executableTarget(
            name: "nes-headless",
            dependencies: ["CFCEUX"],
            path: "Sources/HeadlessRunner"
        ),
        // Wallpaper demo: renders the emulator on a desktop-level window.
        .executableTarget(
            name: "nes-wallpaper",
            dependencies: ["CFCEUX"],
            path: "Sources/WallpaperApp"
        ),
    ],
    cxxLanguageStandard: .gnucxx17
)
