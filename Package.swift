// swift-tools-version: 6.2
import Foundation
import PackageDescription

/// One SwiftPM target per utility. Each compiles on its own against MacToysCore,
/// so a module can be built and tested in isolation: `swift build --target FancyZones`.
let toyModules = [
    "AdvancedPaste", "AlwaysOnTop", "Awake", "ColorPicker", "CommandNotFound", "CommandPalette",
    "CropAndLock", "EnvironmentVariables", "FancyZones", "FinderAddons", "FileLocksmith",
    "GrabAndMove", "HostsEditor", "ImageResizer", "KeyboardManager", "LightSwitch",
    "MouseUtilities", "MouseWithoutBorders", "NewPlus", "Peek", "PowerDisplay", "PowerRename",
    "QuickAccent", "PlistPreview", "ScreenRuler", "ShortcutGuide", "TextExtractor",
    "WindowHopper", "Workspaces", "ZoomIt",
]

/// Extra dependencies beyond MacToysCore.
let extraDependencies: [String: [Target.Dependency]] = [
    "FinderAddons": ["PreviewKit"],
    "Peek": ["PreviewKit"],
]

/// Every target writes its localizable strings (Text("…"), String(localized:), LocalizedStringKey
/// parameters…) as .stringsdata into .build/strings/<target>; scripts/i18n.sh merges them into
/// Resources/Localization/Localizable.xcstrings.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
func swiftSettings(_ target: String) -> [SwiftSetting] {
    [
        .swiftLanguageMode(.v5),
        .unsafeFlags(["-emit-localized-strings", "-emit-localized-strings-path", "\(packageRoot)/.build/strings/\(target)"]),
    ]
}

let moduleTargets: [Target] = toyModules.map { name in
    .target(
        name: name,
        dependencies: ["MacToysCore"] + (extraDependencies[name] ?? []),
        path: "Sources/Modules/\(name)",
        swiftSettings: swiftSettings(name)
    )
}

/// App extensions are plain executables whose entry point is NSExtensionMain;
/// scripts/bundle.sh wraps them into .appex bundles inside MacToys.app.
func appExtension(_ name: String, path: String, dependencies: [Target.Dependency]) -> Target {
    .executableTarget(
        name: name,
        dependencies: dependencies,
        path: path,
        swiftSettings: swiftSettings(name),
        linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
    )
}

let package = Package(
    name: "MacToys",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "MacToys", targets: ["MacToys"]),
        .executable(name: "mactoys-cli", targets: ["MacToysCLI"]),
        .executable(name: "MacToysQuickLook", targets: ["MacToysQuickLook"]),
        .executable(name: "MacToysThumbnails", targets: ["MacToysThumbnails"]),
        .executable(name: "MacToysFinderSync", targets: ["MacToysFinderSync"]),
    ],
    targets: [
        .target(
            name: "MacToysCore",
            path: "Sources/MacToysCore",
            swiftSettings: swiftSettings("MacToysCore"),
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .target(name: "PreviewKit", path: "Sources/PreviewKit", swiftSettings: swiftSettings("PreviewKit")),
        .target(
            name: "MacToysModules",
            dependencies: ["MacToysCore"] + toyModules.map { .target(name: $0) },
            path: "Sources/MacToysModules",
            swiftSettings: swiftSettings("MacToysModules")
        ),
        .executableTarget(
            name: "MacToys",
            dependencies: ["MacToysCore", "MacToysModules"],
            path: "Sources/MacToys",
            swiftSettings: swiftSettings("MacToys")
        ),
        .executableTarget(
            name: "MacToysCLI",
            dependencies: ["MacToysCore", "MacToysModules"] + toyModules.map { .target(name: $0) },
            path: "Sources/MacToysCLI",
            swiftSettings: swiftSettings("MacToysCLI")
        ),
        appExtension("MacToysQuickLook", path: "Sources/Extensions/QuickLookPreview", dependencies: ["PreviewKit"]),
        appExtension("MacToysThumbnails", path: "Sources/Extensions/QuickLookThumbnail", dependencies: ["PreviewKit"]),
        appExtension("MacToysFinderSync", path: "Sources/Extensions/FinderSync", dependencies: []),
        .testTarget(
            name: "MacToysTests",
            dependencies: ["MacToysCore", "PreviewKit"] + toyModules.map { .target(name: $0) },
            path: "Tests/MacToysTests",
            swiftSettings: swiftSettings("MacToysTests")
        ),
    ] + moduleTargets
)
