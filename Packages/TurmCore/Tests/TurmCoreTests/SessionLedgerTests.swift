import Foundation
import Testing
@testable import TurmCore

struct SessionLedgerTests {
    private final class Window {}

    @Test func assignedSessionReportsItsOwner() {
        var ledger = SessionLedger<Window>()
        let window = Window()
        let id = UUID()
        ledger.assign(id, to: window)
        #expect(ledger.owner(of: id) === window)
        #expect(ledger.owner(of: UUID()) == nil)
    }

    @Test func reassigningMovesTheSessionToTheNewOwner() {
        var ledger = SessionLedger<Window>()
        let first = Window()
        let second = Window()
        let id = UUID()
        ledger.assign(id, to: first)
        ledger.assign(id, to: second)
        #expect(ledger.owner(of: id) === second)
    }

    @Test func formerOwnerCannotUnassignAMovedSession() {
        var ledger = SessionLedger<Window>()
        let first = Window()
        let second = Window()
        let id = UUID()
        ledger.assign(id, to: first)
        ledger.assign(id, to: second)
        ledger.unassign(id, from: first)
        #expect(ledger.owner(of: id) === second)
        ledger.unassign(id, from: second)
        #expect(ledger.owner(of: id) == nil)
    }

    @Test func retiringAnOwnerReturnsOnlyItsSessions() {
        var ledger = SessionLedger<Window>()
        let leaving = Window()
        let staying = Window()
        let mine = [UUID(), UUID()]
        let theirs = UUID()
        for id in mine { ledger.assign(id, to: leaving) }
        ledger.assign(theirs, to: staying)
        let retired = ledger.retire(leaving)
        #expect(Set(retired) == Set(mine))
        #expect(ledger.owner(of: theirs) === staying)
        #expect(ledger.owner(of: mine[0]) == nil)
    }

    @Test func deallocatedOwnerLeavesNoClaim() {
        var ledger = SessionLedger<Window>()
        let id = UUID()
        var window: Window? = Window()
        ledger.assign(id, to: window!)
        window = nil
        #expect(ledger.owner(of: id) == nil)
    }
}
