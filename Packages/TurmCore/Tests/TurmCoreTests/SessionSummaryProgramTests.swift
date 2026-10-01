import Foundation
import Testing
@testable import TurmCore

struct SessionSummaryProgramTests {
    private let id = UUID()

    private func summary(program: RunningProgram?) -> SessionSummary {
        SessionSummary(
            id: id, title: "build", location: "~/Projects", phase: .ready, activity: .succeeded, branch: "main", program: program
        )
    }

    @Test func roundTripsWithAProgram() throws {
        let program = try #require(RunningProgram.resolve(command: "claude"))
        let original = summary(program: program)
        let decoded = try JSONDecoder().decode(SessionSummary.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.program == program)
    }

    @Test func roundTripsWithoutAProgram() throws {
        let original = summary(program: nil)
        let decoded = try JSONDecoder().decode(SessionSummary.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.program == nil)
    }

    @Test func payloadFromAnOlderPeerDecodesWithoutAProgram() throws {
        let program = try #require(RunningProgram.resolve(command: "claude"))
        let data = try JSONEncoder().encode(summary(program: program))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["program"] = nil
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(SessionSummary.self, from: legacy)
        #expect(decoded.program == nil)
        #expect(decoded.title == "build")
    }

    @Test func aProgramChangeIsASummaryChange() throws {
        let program = try #require(RunningProgram.resolve(command: "claude"))
        #expect(summary(program: program) != summary(program: nil))
    }

    @Test func sessionChangedCarriesTheProgram() throws {
        let program = try #require(RunningProgram.resolve(command: "claude"))
        let message = CompanionMessage.sessionChanged(summary(program: program))
        let decoded = try JSONDecoder().decode(CompanionMessage.self, from: JSONEncoder().encode(message))
        #expect(decoded == message)
    }
}
