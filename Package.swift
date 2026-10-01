// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VinylShelfFinder",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "VinylShelfFinder", targets: ["VinylShelfFinder"]),
    ],
    targets: [
        // Al forretningslogik: database, sortering, naboer, søgning, Discogs-sync.
        .target(
            name: "VinylCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // SwiftUI-appen.
        .executableTarget(
            name: "VinylShelfFinder",
            dependencies: ["VinylCore"]
        ),
        // Selvtest af kernelogikken (kør: swift run VinylCoreChecks).
        .executableTarget(
            name: "VinylCoreChecks",
            dependencies: ["VinylCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
