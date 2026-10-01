// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SubFont",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "SubFont", targets: ["SubFont"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .systemLibrary(name: "CZlib"),
        .target(name: "SubFontCore", dependencies: ["CSQLite", "CZlib"]),
        .executableTarget(name: "SubFont", dependencies: ["SubFontCore"]),
        .executableTarget(name: "SubFontFontCheck", dependencies: ["SubFontCore"],
                          path: "Tools/SubFontFontCheck"),
        .executableTarget(name: "SubFontChecks", dependencies: ["SubFontCore"],
                          path: "Tests/SubFontCoreTests", resources: [.copy("Fixtures")])
    ]
)
