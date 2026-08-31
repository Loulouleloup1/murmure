# Lot 1 — Core Dictation Walking Skeleton Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hotkey → record → WhisperKit transcription → paste into the active app. At the end of this lot, Louis dictates into Claude Code with Murmure instead of Superwhisper (Voice mode behaviour only — no LLM, no notch UI yet).

**Architecture:** Thin SwiftUI menu-bar app over a pure-logic SPM package. `MurmureCore` (SPM, fast `swift test`) holds WAV writing, key-combo model, pasteboard snapshot logic, and the `DictationSession` state machine behind protocol seams (`Recorder`, `Transcriber`, `TextInserter`). The app target holds the integrations: AVAudioEngine mic tap, Carbon hotkey registration, WhisperKit, CGEvent paste, menu-bar status.

**Tech Stack:** Swift 5.10+, SwiftUI `MenuBarExtra`, XcodeGen (project generation from `project.yml`), SPM, WhisperKit (STT), XCTest.

**Spec:** `docs/specs/2026-08-31-whisper-local-design.md` (§3, §4, §9, §11)

## Global Constraints

- macOS 14.0+ deployment target, Apple Silicon.
- App is menu-bar only: `LSUIElement = true`, no Dock icon.
- STT default model for dictation: Whisper **large-v3-turbo** (spec §3).
- Audio is written to disk WHILE recording — a crash never loses audio (spec §4).
- App Sandbox OFF (AX + CGEvent required); mic usage description required.
- Storage root: `~/Library/Application Support/Murmure/` (`recordings/`, `models/`).
- English for all code, comments, commits; French only in user-facing UI strings later.
- Every task ends with a commit. Unit tests via `swift test` in `MurmureCore/`; app builds via `xcodebuild`.
- WhisperKit API surface must be verified against the PINNED version's README before use (source-driven; the code below matches the documented public API but names may have drifted).
- Manual verification steps are real gates: a task with a manual step is NOT done until its observed behaviour is reported (spec §11 — unit tests alone never close a feature).

---

### Task 1: Project scaffolding

**Files:**
- Create: `project.yml`, `.gitignore`
- Create: `Murmure/MurmureApp.swift`, `Murmure/AppState.swift`
- Create: `MurmureCore/Package.swift`, `MurmureCore/Sources/MurmureCore/Storage.swift`
- Test: `MurmureCore/Tests/MurmureCoreTests/StorageTests.swift`

**Interfaces:**
- Produces: `Storage.appSupportDirectory(subfolder:) -> URL` (creates on demand) — used by every later task.
- Produces: buildable app + testable core package; `AppState` (ObservableObject with `enum Status { idle, recording, transcribing, inserting, failed }`, `@Published var status`) — menu bar icon binds to it, Task 7 drives it.

- [ ] **Step 1: Tooling check**

```bash
which xcodegen || brew install xcodegen
xcodebuild -version
```

- [ ] **Step 2: Write `.gitignore`, `project.yml`, app skeleton, core package**

`.gitignore`:

```
.build/
DerivedData/
*.xcodeproj
xcuserdata/
.DS_Store
benchmark/.venv/
```

(`*.xcodeproj` is ignored because XcodeGen regenerates it from `project.yml`.)

`project.yml`:

```yaml
name: Murmure
options:
  bundleIdPrefix: com.louiscourcier
  deploymentTarget:
    macOS: "14.0"
packages:
  MurmureCore:
    path: MurmureCore
  WhisperKit:
    url: https://github.com/argmaxinc/WhisperKit
    from: "0.9.0"
targets:
  Murmure:
    type: application
    platform: macOS
    sources: [Murmure]
    dependencies:
      - package: MurmureCore
      - package: WhisperKit
    settings:
      base:
        ENABLE_APP_SANDBOX: NO
        CODE_SIGN_IDENTITY: "-"
    info:
      path: Murmure/Info.plist
      properties:
        LSUIElement: true
        NSMicrophoneUsageDescription: "Murmure records your voice to transcribe it locally."
```

`Murmure/AppState.swift`:

```swift
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    enum Status: Equatable {
        case idle, recording, transcribing, inserting, failed
    }

    @Published var status: Status = .idle

    var menuBarSymbol: String {
        switch status {
        case .idle: "waveform"
        case .recording: "waveform.circle.fill"
        case .transcribing: "hourglass"
        case .inserting: "arrow.down.doc"
        case .failed: "exclamationmark.triangle"
        }
    }
}
```

`Murmure/MurmureApp.swift`:

```swift
import MurmureCore
import SwiftUI

@main
struct MurmureApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Murmure", systemImage: appState.menuBarSymbol) {
            Text("Murmure — lot 1")
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .environmentObject(appState)
    }
}
```

`MurmureCore/Package.swift`:

```swift
// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MurmureCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MurmureCore", targets: ["MurmureCore"])],
    targets: [
        .target(name: "MurmureCore"),
        .testTarget(name: "MurmureCoreTests", dependencies: ["MurmureCore"], resources: [.copy("Fixtures")]),
    ]
)
```

`MurmureCore/Sources/MurmureCore/Storage.swift`:

```swift
import Foundation

public enum Storage {
    /// Application Support/Murmure/<subfolder>, created on demand.
    public static func appSupportDirectory(subfolder: String) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("Murmure").appendingPathComponent(subfolder)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
```

- [ ] **Step 3: Write the failing/passing smoke test**

`MurmureCore/Tests/MurmureCoreTests/StorageTests.swift`:

```swift
import XCTest
@testable import MurmureCore

final class StorageTests: XCTestCase {
    func testAppSupportDirectoryIsCreated() throws {
        let url = try Storage.appSupportDirectory(subfolder: "recordings")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertTrue(url.path.hasSuffix("Murmure/recordings"))
    }
}
```

- [ ] **Step 4: Run tests and build**

```bash
cd MurmureCore && swift test && cd ..
xcodegen generate && xcodebuild -project Murmure.xcodeproj -scheme Murmure -configuration Debug build
```
Expected: tests pass; build succeeds (first build downloads WhisperKit — several minutes).

- [ ] **Step 5: Manual check — app runs**

```bash
open "$(xcodebuild -project Murmure.xcodeproj -scheme Murmure -configuration Debug -showBuildSettings | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2; exit}')/Murmure.app"
```
Expected: a waveform icon appears in the menu bar, no Dock icon, Quit works. Report what was observed.

- [ ] **Step 6: Commit**

```bash
git add .gitignore project.yml Murmure/ MurmureCore/
git commit -m "feat(app): scaffolding — menu bar skeleton + MurmureCore package"
```

---

### Task 2: WavWriter (crash-safe on-disk recording)

**Files:**
- Create: `MurmureCore/Sources/MurmureCore/WavWriter.swift`
- Test: `MurmureCore/Tests/MurmureCoreTests/WavWriterTests.swift`

**Interfaces:**
- Produces: `WavWriter(directory: URL, format: AVAudioFormat) throws`; `.append(_ buffer: AVAudioPCMBuffer) throws`; `.url: URL`. Frames hit the file on every append (spec §4: crash never loses audio). Consumed by `AudioRecorder` (Task 3).

- [ ] **Step 1: Write the failing test**

`MurmureCore/Tests/MurmureCoreTests/WavWriterTests.swift`:

```swift
import AVFoundation
import XCTest
@testable import MurmureCore

final class WavWriterTests: XCTestCase {
    func testTwoSecondsOfSilenceProduceAReadableTwoSecondWav() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let writer = try WavWriter(directory: dir, format: format)

        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000 // 1 s of silence
        try writer.append(buffer)
        try writer.append(buffer)

        let readBack = try AVAudioFile(forReading: writer.url)
        XCTAssertEqual(readBack.length, 32_000)
        XCTAssertEqual(readBack.fileFormat.sampleRate, 16_000, accuracy: 1)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd MurmureCore && swift test --filter WavWriterTests
```
Expected: FAIL — `WavWriter` not defined.

- [ ] **Step 3: Implement**

`MurmureCore/Sources/MurmureCore/WavWriter.swift`:

```swift
import AVFoundation
import Foundation

/// Writes PCM buffers to a .wav file as they arrive, so a crash never loses audio.
public final class WavWriter {
    public let url: URL
    private let file: AVAudioFile

    public init(directory: URL, format: AVAudioFormat) throws {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        url = directory.appendingPathComponent("rec-\(stamp).wav")
        file = try AVAudioFile(forWriting: url, settings: format.settings)
    }

    public func append(_ buffer: AVAudioPCMBuffer) throws {
        try file.write(from: buffer)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

```bash
swift test --filter WavWriterTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MurmureCore/
git commit -m "feat(core): WavWriter — progressive on-disk WAV recording"
```

---

### Task 3: AudioRecorder (mic tap)

**Files:**
- Create: `Murmure/AudioRecorder.swift`
- Modify: `Murmure/MurmureApp.swift` (debug menu item)

**Interfaces:**
- Consumes: `WavWriter`, `Storage` (Task 1–2).
- Produces: `final class AudioRecorder` with `func start() throws` and `func stop() -> URL?` (returns the recorded file URL), conforming later to `Recorder` (Task 7 defines the protocol; keep these exact signatures compatible: `start() throws`, `stop()` returning the URL of the finished file).

- [ ] **Step 1: Implement**

`Murmure/AudioRecorder.swift`:

```swift
import AVFoundation
import Foundation
import MurmureCore

/// Taps the default input device and streams buffers into a WavWriter.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var writer: WavWriter?

    func start() throws {
        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        let dir = try Storage.appSupportDirectory(subfolder: "recordings")
        let writer = try WavWriter(directory: dir, format: hwFormat)
        self.writer = writer
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { buffer, _ in
            try? writer.append(buffer)
        }
        try engine.start()
    }

    func stop() -> URL? {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        defer { writer = nil }
        return writer?.url
    }
}
```

Note: recording keeps the hardware format (typically 48 kHz); WhisperKit resamples on load, so no manual resampling here (YAGNI).

- [ ] **Step 2: Add a debug menu item**

In `MurmureApp.swift`, add to the `MenuBarExtra` content (above `Divider()`):

```swift
Button("Debug: record 3 s") {
    let recorder = AudioRecorder()
    try? recorder.start()
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        if let url = recorder.stop() { print("recorded: \(url.path)"); NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}
```

- [ ] **Step 3: Manual round-trip (REQUIRED gate)**

Rebuild, run the app, click "Debug: record 3 s", speak, grant the mic permission when prompted. Finder reveals the WAV — play it with `afplay <path>`. Expected: your voice, ~3 s. Report the observed result.

- [ ] **Step 4: Commit**

```bash
git add Murmure/
git commit -m "feat(app): AudioRecorder — mic tap into crash-safe WAV"
```

---

### Task 4: Global hotkey

**Files:**
- Create: `MurmureCore/Sources/MurmureCore/KeyCombo.swift`
- Create: `Murmure/HotkeyManager.swift`
- Test: `MurmureCore/Tests/MurmureCoreTests/KeyComboTests.swift`

**Interfaces:**
- Produces: `struct KeyCombo: Codable, Equatable { let keyCode: UInt32; let carbonModifiers: UInt32 }` with `static let defaultToggle` (⌥Space). Persisted later in settings; consumed by `HotkeyManager`.
- Produces: `HotkeyManager.register(_ combo: KeyCombo, onPress: @escaping () -> Void)` — app-side Carbon wrapper; Task 7 registers the dictation toggle.

- [ ] **Step 1: Write the failing test**

`MurmureCore/Tests/MurmureCoreTests/KeyComboTests.swift`:

```swift
import XCTest
@testable import MurmureCore

final class KeyComboTests: XCTestCase {
    func testDefaultToggleIsOptionSpace() {
        XCTAssertEqual(KeyCombo.defaultToggle.keyCode, 49) // kVK_Space
        XCTAssertEqual(KeyCombo.defaultToggle.carbonModifiers, 2048) // optionKey
    }

    func testRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(KeyCombo.defaultToggle)
        let back = try JSONDecoder().decode(KeyCombo.self, from: data)
        XCTAssertEqual(back, KeyCombo.defaultToggle)
    }
}
```

- [ ] **Step 2: Run to verify it fails, then implement**

`MurmureCore/Sources/MurmureCore/KeyCombo.swift`:

```swift
import Foundation

/// A global hotkey: Carbon virtual key code + Carbon modifier mask.
public struct KeyCombo: Codable, Equatable {
    public let keyCode: UInt32
    public let carbonModifiers: UInt32

    public init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// Option+Space — Murmure's default dictation toggle.
    public static let defaultToggle = KeyCombo(keyCode: 49, carbonModifiers: 2048)
}
```

Run `swift test --filter KeyComboTests` → PASS.

- [ ] **Step 3: Implement the Carbon wrapper (app target)**

`Murmure/HotkeyManager.swift`:

```swift
import Carbon.HIToolbox
import Foundation
import MurmureCore

/// Registers one global hotkey via Carbon RegisterEventHotKey.
final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var onPress: (() -> Void)?

    func register(_ combo: KeyCombo, onPress: @escaping () -> Void) {
        self.onPress = onPress
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue().onPress?()
            return noErr
        }, 1, &eventType, selfPtr, &eventHandler)
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D55_524D), id: 1) // "MURM"
        RegisterEventHotKey(
            combo.keyCode, combo.carbonModifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
```

- [ ] **Step 4: Wire a visible manual check**

In `MurmureApp.swift`, give `AppState` a `let hotkeys = HotkeyManager()` and in an `.onAppear`-equivalent (`init` of the App struct is fine) register `KeyCombo.defaultToggle` with `appState.status = appState.status == .idle ? .recording : .idle` toggling. Rebuild, run: pressing ⌥Space anywhere (even with another app focused) flips the menu-bar icon. Report observed behaviour. (This temporary toggle body is replaced in Task 7.)

- [ ] **Step 5: Commit**

```bash
git add Murmure/ MurmureCore/
git commit -m "feat: global hotkey — KeyCombo model + Carbon registration (default ⌥Space)"
```

---

### Task 5: WhisperKit transcription engine

**Files:**
- Create: `Murmure/WhisperKitEngine.swift`
- Create: `MurmureCore/Tests/MurmureCoreTests/Fixtures/bonjour.wav` (recorded in this task)

**Interfaces:**
- Produces: `final class WhisperKitEngine` with `func transcribe(wav: URL) async throws -> String`, lazy model load, model files under `Storage.appSupportDirectory(subfolder: "models")`. Conforms to Task 7's `Transcriber` protocol (exact same signature).

- [ ] **Step 1: Verify the pinned WhisperKit API (source-driven — REQUIRED before coding)**

Read the README/docs of the WhisperKit version resolved in `Murmure.xcodeproj` (check `xcodebuild -resolvePackageDependencies` output or Package.resolved). Confirm: the initializer taking a model name, the `transcribe(audioPath:)` entry point and its return type, the model-folder override parameter, and the exact model identifier string for **large-v3-turbo** in its supported-models list. Adjust Step 2's code accordingly — note any drift in the commit message.

- [ ] **Step 2: Implement**

`Murmure/WhisperKitEngine.swift` (matches WhisperKit's documented API as of 0.9; adjust per Step 1):

```swift
import Foundation
import MurmureCore
import WhisperKit

/// WhisperKit-backed speech-to-text. Downloads the model on first use.
final class WhisperKitEngine {
    static let dictationModel = "openai_whisper-large-v3-v20240930_turbo" // verify in Step 1

    private var kit: WhisperKit?

    func transcribe(wav: URL) async throws -> String {
        if kit == nil {
            let modelFolder = try Storage.appSupportDirectory(subfolder: "models")
            kit = try await WhisperKit(
                model: Self.dictationModel,
                downloadBase: modelFolder,
                verbose: false
            )
        }
        let results = try await kit!.transcribe(audioPath: wav.path)
        return results.map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 3: Record the fixture and run the real transcription check (REQUIRED gate)**

Using Task 3's debug menu item, record a 3 s clip saying clearly: « Bonjour, ceci est un test de Murmure. » Copy it to `MurmureCore/Tests/MurmureCoreTests/Fixtures/bonjour.wav`.

Add a temporary debug menu item "Debug: transcribe fixture" that runs `WhisperKitEngine().transcribe(wav:)` on that file and `print`s the result. Run it (first run downloads ~1.6 GB — report progress/duration). Expected: printed text contains "onjour" and "urmure" (case/diacritic tolerant). Report the exact transcription observed.

- [ ] **Step 4: Commit**

```bash
git add Murmure/ MurmureCore/
git commit -m "feat(app): WhisperKitEngine — large-v3-turbo transcription with local model store"
```

---

### Task 6: Paste inserter with clipboard restore

**Files:**
- Create: `MurmureCore/Sources/MurmureCore/PasteboardSnapshot.swift`
- Create: `Murmure/PasteInserter.swift`
- Test: `MurmureCore/Tests/MurmureCoreTests/PasteboardSnapshotTests.swift`

**Interfaces:**
- Produces (core): `struct PasteboardSnapshot { static func capture(from:) -> PasteboardSnapshot; func restore(to:) }` — save/restore ALL pasteboard item types, not just strings.
- Produces (app): `final class PasteInserter` with `func insert(_ text: String) async throws` — snapshot → set text → synthesize ⌘V → wait → restore. Conforms to Task 7's `TextInserter`. Throws `InsertError.accessibilityDenied` when `AXIsProcessTrusted()` is false.

- [ ] **Step 1: Write the failing test (snapshot round-trip)**

`MurmureCore/Tests/MurmureCoreTests/PasteboardSnapshotTests.swift`:

```swift
import AppKit
import XCTest
@testable import MurmureCore

final class PasteboardSnapshotTests: XCTestCase {
    func testSnapshotRestoresPreviousStringContent() {
        let pb = NSPasteboard(name: NSPasteboard.Name("murmure-test-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("original content", forType: .string)

        let snapshot = PasteboardSnapshot.capture(from: pb)
        pb.clearContents()
        pb.setString("dictated text", forType: .string)
        XCTAssertEqual(pb.string(forType: .string), "dictated text")

        snapshot.restore(to: pb)
        XCTAssertEqual(pb.string(forType: .string), "original content")
    }

    func testEmptyPasteboardRestoresToEmpty() {
        let pb = NSPasteboard(name: NSPasteboard.Name("murmure-test-\(UUID().uuidString)"))
        pb.clearContents()
        let snapshot = PasteboardSnapshot.capture(from: pb)
        pb.setString("noise", forType: .string)
        snapshot.restore(to: pb)
        XCTAssertNil(pb.string(forType: .string))
    }
}
```

- [ ] **Step 2: Run to verify it fails, then implement**

`MurmureCore/Sources/MurmureCore/PasteboardSnapshot.swift`:

```swift
import AppKit

/// Byte-for-byte snapshot of pasteboard items, restorable after a paste.
public struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    public static func capture(from pasteboard: NSPasteboard = .general) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { acc, type in
                if let data = item.data(forType: type) { acc[type] = data }
            }
        }
        return PasteboardSnapshot(items: items)
    }

    public func restore(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}
```

Run `swift test --filter PasteboardSnapshotTests` → PASS.

- [ ] **Step 3: Implement the app-side inserter**

`Murmure/PasteInserter.swift`:

```swift
import AppKit
import ApplicationServices
import Foundation
import MurmureCore

enum InsertError: Error {
    case accessibilityDenied
}

/// Inserts text into the frontmost app: snapshot clipboard → set text → ⌘V → restore.
final class PasteInserter {
    func insert(_ text: String) async throws {
        guard AXIsProcessTrusted() else { throw InsertError.accessibilityDenied }

        let snapshot = PasteboardSnapshot.capture()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true) // kVK_ANSI_V
        vDown?.flags = .maskCommand
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        vUp?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)

        // Give the target app time to consume the paste before restoring.
        try await Task.sleep(for: .milliseconds(300))
        snapshot.restore()
    }

    /// Triggers the system Accessibility prompt on first launch.
    static func requestAccessibilityIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
```

Call `PasteInserter.requestAccessibilityIfNeeded()` once at app launch (in `MurmureApp.init`).

- [ ] **Step 4: TextEdit round-trip (REQUIRED gate)**

Add a debug menu item "Debug: insert in 3 s" calling `try await PasteInserter().insert("murmure round-trip \(Int.random(in: 100...999))")` after a 3 s delay. Then:

```bash
osascript -e 'tell application "TextEdit" to activate' -e 'tell application "TextEdit" to make new document'
# click the menu item, then click into the TextEdit document within 3 s
sleep 5
osascript -e 'tell application "TextEdit" to get text of document 1'
pbpaste  # verify the clipboard was RESTORED to its pre-insert content, not the dictated text
```
Expected: TextEdit contains "murmure round-trip NNN"; `pbpaste` shows the previous clipboard content byte-for-byte. Grant Accessibility to the built Murmure.app in System Settings when prompted (a rebuilt binary may need re-granting). Report both observations.

- [ ] **Step 5: Commit**

```bash
git add Murmure/ MurmureCore/
git commit -m "feat: paste insertion with full pasteboard snapshot/restore + AX gate"
```

---

### Task 7: DictationSession state machine + end-to-end wiring

**Files:**
- Create: `MurmureCore/Sources/MurmureCore/DictationSession.swift`
- Create: `Murmure/DictationController.swift`
- Modify: `Murmure/MurmureApp.swift`, `Murmure/AudioRecorder.swift`, `Murmure/WhisperKitEngine.swift`, `Murmure/PasteInserter.swift` (protocol conformances)
- Test: `MurmureCore/Tests/MurmureCoreTests/DictationSessionTests.swift`

**Interfaces:**
- Produces (core): the protocol seams and the session:

```swift
public protocol Recorder { func start() throws; func stop() -> URL? }
public protocol Transcriber { func transcribe(wav: URL) async throws -> String }
public protocol TextInserter { func insert(_ text: String) async throws }

public actor DictationSession {
    public enum State: Equatable {
        case idle, recording, transcribing, inserting
        case failed(message: String, recoveredText: String?)
    }
    public private(set) var state: State
    public private(set) var lastTranscript: String?
    public init(recorder: Recorder, transcriber: Transcriber, inserter: TextInserter,
                onStateChange: @escaping @Sendable (State) -> Void)
    /// Hotkey entry point: starts recording from idle, otherwise stops and runs the pipeline.
    public func toggle() async
}
```
- Consumes: Tasks 3/5/6 classes, which get one-line `extension … : Recorder/Transcriber/TextInserter` conformances (signatures already match).

- [ ] **Step 1: Write the failing tests**

`MurmureCore/Tests/MurmureCoreTests/DictationSessionTests.swift`:

```swift
import XCTest
@testable import MurmureCore

private final class FakeRecorder: Recorder {
    var started = false
    func start() throws { started = true }
    func stop() -> URL? { URL(fileURLWithPath: "/tmp/fake.wav") }
}

private struct FakeTranscriber: Transcriber {
    var result: Result<String, Error>
    func transcribe(wav: URL) async throws -> String { try result.get() }
}

private final class SpyInserter: TextInserter, @unchecked Sendable {
    var inserted: [String] = []
    var error: Error?
    func insert(_ text: String) async throws {
        if let error { throw error }
        inserted.append(text)
    }
}

private struct TestError: Error {}

final class DictationSessionTests: XCTestCase {
    func testFullToggleCycleInsertsTranscriptAndReturnsToIdle() async {
        let inserter = SpyInserter()
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .success("bonjour murmure")),
            inserter: inserter, onStateChange: { _ in }
        )
        await session.toggle() // start
        let recordingState = await session.state
        XCTAssertEqual(recordingState, .recording)
        await session.toggle() // stop + pipeline
        XCTAssertEqual(inserter.inserted, ["bonjour murmure"])
        let finalState = await session.state
        XCTAssertEqual(finalState, .idle)
    }

    func testTranscriberFailureLandsInFailedStateWithNoInsert() async {
        let inserter = SpyInserter()
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .failure(TestError())),
            inserter: inserter, onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()
        XCTAssertTrue(inserter.inserted.isEmpty)
        guard case .failed(_, let recovered) = await session.state else {
            return XCTFail("expected failed state")
        }
        XCTAssertNil(recovered)
    }

    func testInsertFailureKeepsTranscriptForRecovery() async {
        let inserter = SpyInserter()
        inserter.error = TestError()
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .success("texte précieux")),
            inserter: inserter, onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()
        guard case .failed(_, let recovered) = await session.state else {
            return XCTFail("expected failed state")
        }
        XCTAssertEqual(recovered, "texte précieux") // never lose a dictation (spec §9)
    }
}
```

- [ ] **Step 2: Run to verify they fail, then implement**

`MurmureCore/Sources/MurmureCore/DictationSession.swift`:

```swift
import Foundation

public protocol Recorder {
    func start() throws
    func stop() -> URL?
}

public protocol Transcriber {
    func transcribe(wav: URL) async throws -> String
}

public protocol TextInserter {
    func insert(_ text: String) async throws
}

/// One dictation end-to-end: idle → recording → transcribing → inserting → idle/failed.
public actor DictationSession {
    public enum State: Equatable {
        case idle, recording, transcribing, inserting
        case failed(message: String, recoveredText: String?)
    }

    public private(set) var state: State = .idle
    public private(set) var lastTranscript: String?

    private let recorder: Recorder
    private let transcriber: Transcriber
    private let inserter: TextInserter
    private let onStateChange: @Sendable (State) -> Void

    public init(
        recorder: Recorder, transcriber: Transcriber, inserter: TextInserter,
        onStateChange: @escaping @Sendable (State) -> Void
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.inserter = inserter
        self.onStateChange = onStateChange
    }

    public func toggle() async {
        switch state {
        case .recording:
            await finishRecording()
        case .transcribing, .inserting:
            break // pipeline already running; ignore extra presses
        case .idle, .failed:
            do {
                try recorder.start()
                transition(to: .recording)
            } catch {
                transition(to: .failed(message: "mic start failed: \(error)", recoveredText: nil))
            }
        }
    }

    private func finishRecording() async {
        guard let wav = recorder.stop() else {
            transition(to: .failed(message: "no audio captured", recoveredText: nil))
            return
        }
        transition(to: .transcribing)
        let text: String
        do {
            text = try await transcriber.transcribe(wav: wav)
        } catch {
            transition(to: .failed(message: "transcription failed: \(error)", recoveredText: nil))
            return
        }
        lastTranscript = text
        transition(to: .inserting)
        do {
            try await inserter.insert(text)
            transition(to: .idle)
        } catch {
            // Spec §9: the dictation is never lost — keep the text for recovery.
            transition(to: .failed(message: "insert failed: \(error)", recoveredText: text))
        }
    }

    private func transition(to newState: State) {
        state = newState
        onStateChange(newState)
    }
}
```

Run `swift test --filter DictationSessionTests` → PASS. Run the full suite: `swift test` → all green.

- [ ] **Step 3: Wire the app**

Add conformances (one line each): `extension AudioRecorder: Recorder {}`, `extension WhisperKitEngine: Transcriber {}`, `extension PasteInserter: TextInserter {}`.

`Murmure/DictationController.swift`:

```swift
import Foundation
import MurmureCore
import SwiftUI

/// Owns the session and binds its state to the menu bar.
@MainActor
final class DictationController {
    private let session: DictationSession
    private let hotkeys = HotkeyManager()

    init(appState: AppState) {
        session = DictationSession(
            recorder: AudioRecorder(),
            transcriber: WhisperKitEngine(),
            inserter: PasteInserter()
        ) { state in
            Task { @MainActor in
                appState.status = switch state {
                case .idle: .idle
                case .recording: .recording
                case .transcribing: .transcribing
                case .inserting: .inserting
                case .failed: .failed
                }
            }
        }
        hotkeys.register(.defaultToggle) { [session] in
            Task { await session.toggle() }
        }
    }

    /// Menu action for the failed state: re-paste the recovered text.
    func repasteLast() {
        Task {
            if let text = await session.lastTranscript {
                try? await PasteInserter().insert(text)
            }
        }
    }
}
```

In `MurmureApp.swift`: instantiate the controller once (`@State private var controller: DictationController?` initialised in `init` via the shared `AppState`), remove Task 4's temporary hotkey body and Task 3/5/6's debug menu items, add menu items "Re-paste last transcript" (calls `repasteLast()`) and keep Quit.

- [ ] **Step 4: End-to-end round-trip (FINAL GATE — real usage, per spec §11)**

Rebuild, launch, grant permissions. Then, for real:
1. Open TextEdit → press ⌥Space → say « ceci est une dictée de test complète » → press ⌥Space. Expected: the sentence appears at the cursor within a few seconds; menu icon cycles waveform → record → hourglass → insert → waveform.
2. Repeat inside a terminal running Claude Code (Louis's real use case).
3. Copy something to the clipboard first and verify it is intact after the dictation (`pbpaste`).
Report all three observations verbatim. This step is done by Louis or with Louis watching — it is the lot's acceptance gate.

- [ ] **Step 5: Commit**

```bash
git add Murmure/ MurmureCore/
git commit -m "feat: DictationSession end-to-end — hotkey dictation into the active app"
```
