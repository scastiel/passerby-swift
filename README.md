# passerby-swift

The iOS Tracker for [Passerby](https://github.com/scastiel/passerby), self-hosted, privacy-friendly
analytics read by your AI agents. It sends Views of the Screens you name and your Custom events to
your Instance, and nothing else: no device identifier, nothing written to disk, no prompt.

iOS 16+ (iPadOS included), Swift 5.9+ / Xcode 15+, clean in the Swift 6 language mode.

## Install

In Xcode, **File → Add Package Dependencies…** and enter
`https://github.com/scastiel/passerby-swift`. Or in `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/scastiel/passerby-swift", from: "1.0.0")
],
targets: [
  .target(name: "MyApp", dependencies: [.product(name: "Passerby", package: "passerby-swift")])
]
```

## Use

Three calls. Configure once at launch with the line `passerby app create` printed (the App key and
your Instance's public URL), then name your Screens and record what matters:

```swift
import Passerby
import SwiftUI

@main struct MyApp: App {
  init() {
    Passerby.configure(appKey: "k7f3x9q2m1pz", url: URL(string: "https://analytics.example.com")!)
  }
  var body: some Scene { WindowGroup { RootView() } }
}

struct SettingsView: View {
  var body: some View {
    Form { /* ... */ }.trackScreen("Settings")
  }
}

Passerby.event("signup", props: ["plan": "pro", "seats": 3, "trial": true])
```

- `.trackScreen(_:props:)` records a View on every `onAppear`: a tab shown three times is three
  Views. Outside SwiftUI, call `Passerby.view("Settings")` yourself (from `viewDidAppear`, say).
  Screens are always named by you; nothing is captured automatically.
- `Passerby.event(_:props:)` records a Custom event on the last Screen seen.
- Properties are strings, numbers or booleans, written as literals. The Collector checks the limits
  (20 pairs, 256-character strings, 2 KB) and rejects what breaks them; rejections show up in the
  console (below).
- Every call is safe from any thread and returns immediately. A call made before `configure` does
  nothing but log a line.

### Debug builds

A DEBUG build sends nothing unless you opt in, so development never lands in your real numbers. To
try your integration, create a separate App for development and pass its key:

```swift
#if DEBUG
  Passerby.configure(appKey: "<development key>", url: instanceURL, sendInDebugBuilds: true)
#else
  Passerby.configure(appKey: "k7f3x9q2m1pz", url: instanceURL)
#endif
```

Release builds, TestFlight included, always send. The Tracker logs through `os.Logger` under the
category `Passerby`: each send at `.debug`, and each rejection, dropped batch and network failure at
`.error` with the Collector's reason. Filter the Xcode console on `Passerby` to see them.

## What it sends, and when

Each Event carries the Screen, the name, its Properties, the time, a Visit id, the app's marketing
version (`CFBundleShortVersionString`) and the model identifier (`iPhone15,2`); the request's
User-Agent is `iOS/<version> <locale>`. The Visit id is a random UUID minted at launch and again
after 30 minutes without an Event; it lives in memory only, and backgrounding never ends a Visit.

Events queue in memory and go out in batches of up to 25: every 5 seconds, as soon as 25 are
pending, and when the app enters the background. A network error, a `5xx` or a `429` keeps the
batch and retries with backoff (5 seconds doubling to 5 minutes, or the `Retry-After` the Collector
gave); any other `4xx` drops it and logs why. The queue holds at most 500 Events, dropping the
oldest. Nothing is written to disk, so Events still queued when iOS terminates the app are lost:
that is the price of keeping nothing on the device.

## Privacy manifest

The package ships a `PrivacyInfo.xcprivacy` that Xcode merges into your app's privacy report:
`NSPrivacyTracking` is `false`, there are no tracking domains, and the collected data types are
**Product Interaction** and **Coarse Location** (the country your Instance derives from the IP),
both for Analytics, not linked to the user and not used for tracking. The Tracker uses no
required-reason API: no `UserDefaults`, no Keychain, no file timestamps, no `identifierForVendor`.
No App Tracking Transparency prompt is needed. In App Store Connect's privacy questions, declare the
same two types with the same answers.

## Develop

```sh
xcodebuild test -scheme Passerby -destination 'platform=iOS Simulator,name=iPhone 16'
```

The suite stubs the Collector with a `URLProtocol` and drives time by hand, so it never sleeps. One
test runs the real Tracker against a real Instance and is skipped unless you give it one:

```sh
passerby migrate && passerby app create swift-e2e   # note the key
passerby serve --listen 127.0.0.1:8080 &
TEST_RUNNER_PASSERBY_E2E_URL=http://127.0.0.1:8080 TEST_RUNNER_PASSERBY_E2E_APP_KEY=<key> \
  xcodebuild test -scheme Passerby -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:PasserbyTests/EndToEndTests
passerby export swift-e2e   # the View and the Custom event, platform ios
```

The package versions on its own semver tags, independently of the Collector; the envelope in
[`docs/tracker-contracts.md`](https://github.com/scastiel/passerby/blob/main/docs/tracker-contracts.md)
is what binds them.

## License

MIT
