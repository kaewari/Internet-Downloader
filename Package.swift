// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "InternetDownloader",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "DownloaderCore", targets: ["DownloaderCore"]),
        .executable(name: "internet-downloader-host", targets: ["NativeHost"]),
        .executable(name: "InternetDownloader", targets: ["InternetDownloaderApp"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "DownloaderCore",
            dependencies: [],
            path: "Sources/DownloaderCore"
        ),
        .executableTarget(
            name: "NativeHost",
            dependencies: ["DownloaderCore"],
            path: "Sources/NativeHost"
        ),
        .executableTarget(
            name: "InternetDownloaderApp",
            dependencies: ["DownloaderCore"],
            path: "Sources/InternetDownloaderApp"
        ),
        .testTarget(
            name: "DownloaderCoreTests",
            dependencies: ["DownloaderCore"],
            path: "Tests/DownloaderCoreTests"
        )
    ]
)
