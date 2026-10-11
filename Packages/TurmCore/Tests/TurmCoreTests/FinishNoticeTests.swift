import Foundation
import Testing
@testable import TurmCore

struct FinishNoticeTests {
    private let defaults = FinishNoticeSettings()

    @Test func frontmostAppReturnsNil() {
        let result = FinishNoticePolicy.notice(
            command: "make",
            exitCode: 0,
            duration: .seconds(5),
            shellEnabled: true,
            isWatching: true,
            appIsFrontmost: true,
            settings: defaults
        )
        #expect(result == nil)
    }

    @Test func disabledSettingReturnsNil() {
        var settings = defaults
        settings.enabled = false
        let result = FinishNoticePolicy.notice(
            command: "make",
            exitCode: 0,
            duration: .seconds(5),
            shellEnabled: true,
            isWatching: true,
            appIsFrontmost: false,
            settings: settings
        )
        #expect(result == nil)
    }

    @Test func disabledShellReturnsNil() {
        let result = FinishNoticePolicy.notice(
            command: "make",
            exitCode: 0,
            duration: .seconds(5),
            shellEnabled: false,
            isWatching: true,
            appIsFrontmost: false,
            settings: defaults
        )
        #expect(result == nil)
    }

    @Test func notWatchingReturnsNil() {
        let result = FinishNoticePolicy.notice(
            command: "make",
            exitCode: 0,
            duration: .seconds(5),
            shellEnabled: true,
            isWatching: false,
            appIsFrontmost: false,
            settings: defaults
        )
        #expect(result == nil)
    }

    @Test func durationBelowMinimumReturnsNilEqualReturnsNotice() {
        var settings = defaults
        settings.minimumDuration = .seconds(10)

        let below = FinishNoticePolicy.notice(
            command: "make",
            exitCode: 0,
            duration: .seconds(9),
            shellEnabled: true,
            isWatching: true,
            appIsFrontmost: false,
            settings: settings
        )
        #expect(below == nil)

        let equal = FinishNoticePolicy.notice(
            command: "make",
            exitCode: 0,
            duration: .seconds(10),
            shellEnabled: true,
            isWatching: true,
            appIsFrontmost: false,
            settings: settings
        )
        #expect(equal != nil)
    }

    @Test func onlyOnFailureSuppressesExitZeroAndNilAllowsExitOne() {
        var settings = defaults
        settings.onlyOnFailure = true

        let exitZero = FinishNoticePolicy.notice(
            command: "make",
            exitCode: 0,
            duration: .seconds(5),
            shellEnabled: true,
            isWatching: true,
            appIsFrontmost: false,
            settings: settings
        )
        #expect(exitZero == nil)

        let exitNil = FinishNoticePolicy.notice(
            command: "make",
            exitCode: nil,
            duration: .seconds(5),
            shellEnabled: true,
            isWatching: true,
            appIsFrontmost: false,
            settings: settings
        )
        #expect(exitNil == nil)

        let exitOne = FinishNoticePolicy.notice(
            command: "make",
            exitCode: 1,
            duration: .seconds(90),
            shellEnabled: true,
            isWatching: true,
            appIsFrontmost: false,
            settings: settings
        )
        #expect(exitOne != nil)
        #expect(exitOne?.body.contains("Failed (1)") == true)
        #expect(exitOne?.body.contains("1m 30s") == true)
    }

    @Test func longCommandTruncatedWithEllipsis() {
        let longCommand = String(repeating: "a", count: 100)
        let result = FinishNoticePolicy.notice(
            command: longCommand,
            exitCode: 0,
            duration: .seconds(5),
            shellEnabled: true,
            isWatching: true,
            appIsFrontmost: false,
            settings: defaults
        )
        #expect(result != nil)
        #expect(result?.title.count == 80)
        #expect(result?.title.hasSuffix("\u{2026}") == true)
    }

    @Test func emptyCommandTitlesTurm() {
        let result = FinishNoticePolicy.notice(
            command: "",
            exitCode: 0,
            duration: .seconds(5),
            shellEnabled: true,
            isWatching: true,
            appIsFrontmost: false,
            settings: defaults
        )
        #expect(result?.title == "Turm")
    }

    @Test func formatDuration() {
        #expect(FinishNoticePolicy.format(duration: .seconds(0)) == "0s")
        #expect(FinishNoticePolicy.format(duration: .seconds(12)) == "12s")
        #expect(FinishNoticePolicy.format(duration: .seconds(90)) == "1m 30s")
        #expect(FinishNoticePolicy.format(duration: .seconds(60)) == "1m 0s")
    }

    @Test func settingsRoundTripThroughJSON() throws {
        let settings = FinishNoticeSettings(
            enabled: true,
            minimumDuration: .seconds(3.5),
            onlyOnFailure: false
        )
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(FinishNoticeSettings.self, from: data)
        #expect(decoded == settings)
        #expect(decoded.minimumDuration == .seconds(3.5))
    }
}
