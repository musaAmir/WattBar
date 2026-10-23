// swift-tools-version: 5.9
import PackageDescription

let package = Package(name: "WattBarCore", platforms: [.macOS(.v13)],
    products: [.library(name: "WattBarCore", targets: ["WattBarCore"])],
    targets: [
        .target(name: "WattBarCore", path: "WattBar", exclude: ["EnergyDetailView.swift","MenuDashboardModel.swift", "MenuDashboardView.swift", "WattBarApp.swift", "PreferencesView.swift", "Info.plist", "WattBar.entitlements", "Assets.xcassets"], sources: ["PowerData.swift", "SMC.swift", "EnergyHistory.swift", "EnergyHistoryStore.swift", "AppActivityData.swift", "AppActivityMonitor.swift", "AppActivityHistory.swift", "AppActivityHistoryStore.swift"]),
        .testTarget(name: "WattBarCoreTests", dependencies: ["WattBarCore"], path: "Tests/WattBarCoreTests")
    ])
