// FineTuneTests/AudioEngineTapProcessSetTests.swift
import Testing
import Foundation
import AppKit
import AudioToolbox
@testable import FineTune

@Suite("AudioEngine rebuilds taps when an app gains processes")
@MainActor
struct AudioEngineTapProcessSetTests {
    @Test("A process merged into an app after its tap exists gets tapped")
    func newProcessIsTapped() async throws -> Void {
        let fix: ProcessSetFixture = makeProcessSetFixture()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.deviceUID)
        let firstTap: RecordingProcessTapController = try #require(fix.taps.all.last)
        #expect(firstTap.app.processObjectIDs == [10])

        fix.processMonitor.activeApps = [fix.app.withProcessObjectIDs([10, 11])]
        fix.engine.applyPersistedSettings()
        try await waitUntil { fix.taps.all.count == 2 }

        let rebuilt: RecordingProcessTapController = try #require(fix.taps.all.last)
        #expect(rebuilt.app.processObjectIDs == [10, 11])
        #expect(firstTap.events.contains(.invalidate))
    }

    @Test("A process leaving an app does not rebuild its tap")
    func exitedProcessKeepsTap() async throws -> Void {
        let fix: ProcessSetFixture = makeProcessSetFixture(initialProcessObjectIDs: [10, 11])
        fix.engine.setDevice(for: fix.app, deviceUID: fix.deviceUID)

        fix.processMonitor.activeApps = [fix.app.withProcessObjectIDs([10])]
        fix.engine.applyPersistedSettings()
        for _ in 0..<20 { await Task.yield() }

        #expect(fix.taps.all.count == 1)
    }
}

private extension AudioApp {
    func withProcessObjectIDs(_ ids: [AudioObjectID]) -> AudioApp {
        AudioApp(id: id, processObjectIDs: ids, name: name, icon: icon, bundleID: bundleID, isHelperBacked: isHelperBacked)
    }
}

@MainActor
private final class TapLog {
    var all: [RecordingProcessTapController] = []
}

@MainActor
private struct ProcessSetFixture {
    let engine: AudioEngine
    let processMonitor: StubProcessMonitor
    let app: AudioApp
    let deviceUID: String
    let taps: TapLog
}

@MainActor
private func makeProcessSetFixture(initialProcessObjectIDs: [AudioObjectID] = [10]) -> ProcessSetFixture {
    let tempDir: URL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let settings = SettingsManager(directory: tempDir)
    let deviceMonitor = MockAudioDeviceMonitor()
    let device = AudioDevice(id: AudioDeviceID(99), uid: "uid-test", name: "Test Output", icon: nil, supportsAutoEQ: false)
    deviceMonitor.addOutputDevice(device)

    let app = AudioApp(id: 4242, processObjectIDs: initialProcessObjectIDs, name: "Claude", icon: NSImage(), bundleID: "com.test.processset")
    let processMonitor = StubProcessMonitor()
    processMonitor.activeApps = [app]

    let permission = AudioRecordingPermission()
    permission.status = .authorized

    let log = TapLog()
    let engine = AudioEngine(
        permission: permission,
        settingsManager: settings,
        autoEQProfileManager: AutoEQProfileManager(),
        deviceProvider: deviceMonitor,
        processMonitor: processMonitor,
        deviceVolumeMonitor: MockDeviceVolumeProviding(deviceMonitor: deviceMonitor),
        tapFactory: { app, uids, _ in
            let tap = RecordingProcessTapController(app: app, deviceUIDs: uids)
            log.all.append(tap)
            return tap
        },
        startMonitorsAutomatically: false
    )
    return ProcessSetFixture(engine: engine, processMonitor: processMonitor, app: app, deviceUID: device.uid, taps: log)
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws -> Void {
    for _ in 0..<200 {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("Condition not met in time")
}
