// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NESWallpaper",
    platforms: [.macOS(.v14)],
    products: [
        // Loadable code for the .saver bundle; Scripts/make-app.sh wraps
        // this dylib in the bundle structure legacyScreenSaver expects.
        .library(name: "NESWallpaperSaver", type: .dynamic, targets: ["SaverPlugin"]),
    ],
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
            cSettings: [
                // nes_ntsc.c is the one C file in the core; the cxxSettings
                // -Wno-everything below doesn't reach it.
                .unsafeFlags([
                    "-Wno-everything",
                ]),
            ],
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
        // Shared-memory frame transport between helper processes and the app.
        .target(
            name: "CShm",
            path: "Sources/CShm",
            sources: ["src"],
            publicHeadersPath: "include"
        ),
        // CLI harness: run a ROM (+ optional FM2) headless, dump PNG frames.
        .executableTarget(
            name: "nes-headless",
            dependencies: ["CFCEUX"],
            path: "Sources/HeadlessRunner"
        ),
        // Helper: one emulator instance, publishes frames to shared memory.
        .executableTarget(
            name: "nes-helper",
            dependencies: ["CFCEUX", "CShm"],
            path: "Sources/HelperApp"
        ),
        // App-side tile management and wallpaper window rendering.
        .target(
            name: "NESWallpaperCore",
            dependencies: ["CShm"],
            path: "Sources/NESWallpaperCore"
        ),
        // Wallpaper app: spawns one helper per tile, renders the grid.
        .executableTarget(
            name: "nes-wallpaper",
            dependencies: ["NESWallpaperCore", "CShm", "CFCEUX"],
            path: "Sources/WallpaperApp"
        ),
        // Screensaver plugin: read-only client of the app's frame files.
        .target(
            name: "SaverPlugin",
            dependencies: ["NESWallpaperCore", "CShm"],
            path: "Sources/SaverPlugin",
            linkerSettings: [
                .linkedFramework("ScreenSaver"),
            ]
        ),
        .testTarget(
            name: "NESWallpaperCoreTests",
            dependencies: ["NESWallpaperCore", "CFCEUX"],
            path: "Tests/NESWallpaperCoreTests"
        ),
    ],
    cxxLanguageStandard: .gnucxx17
)
