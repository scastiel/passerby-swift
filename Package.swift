// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "Passerby",
  platforms: [.iOS(.v16)],
  products: [
    .library(name: "Passerby", targets: ["Passerby"])
  ],
  targets: [
    .target(
      name: "Passerby",
      resources: [.copy("PrivacyInfo.xcprivacy")]
    ),
    .testTarget(name: "PasserbyTests", dependencies: ["Passerby"]),
  ]
)
