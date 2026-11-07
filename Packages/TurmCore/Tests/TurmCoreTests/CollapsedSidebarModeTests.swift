import Foundation
import Testing
@testable import TurmCore

struct CollapsedSidebarModeTests {
    private func defaults() -> UserDefaults {
        let name = "CollapsedSidebarModeTests-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        return store
    }

    @Test func bothAreOnByDefault() {
        let mode = CollapsedSidebarMode(defaults: defaults())
        #expect(mode.topBar)
        #expect(mode.popOut)
    }

    @Test func eachCanBeOffAlone() {
        let noBar = CollapsedSidebarMode(topBar: false, popOut: true)
        #expect(!noBar.topBar && noBar.popOut)
        let noPopOut = CollapsedSidebarMode(topBar: true, popOut: false)
        #expect(noPopOut.topBar && !noPopOut.popOut)
    }

    @Test func bothOffFallsBackToTheTopBar() {
        let mode = CollapsedSidebarMode(topBar: false, popOut: false)
        #expect(mode.topBar)
        #expect(!mode.popOut)
    }

    @Test func storedValuesAreRead() {
        let store = defaults()
        store.set(false, forKey: CollapsedSidebarMode.topBarKey)
        store.set(true, forKey: CollapsedSidebarMode.popOutKey)
        #expect(CollapsedSidebarMode(defaults: store) == CollapsedSidebarMode(topBar: false, popOut: true))
        store.set(false, forKey: CollapsedSidebarMode.popOutKey)
        #expect(CollapsedSidebarMode(defaults: store) == CollapsedSidebarMode(topBar: true, popOut: false))
    }

    @Test func theLastSwitchOnCannotBeTurnedOff() {
        let both = CollapsedSidebarMode()
        #expect(both.canDisableTopBar && both.canDisablePopOut)
        let barOnly = CollapsedSidebarMode(topBar: true, popOut: false)
        #expect(!barOnly.canDisableTopBar)
        let popOutOnly = CollapsedSidebarMode(topBar: false, popOut: true)
        #expect(!popOutOnly.canDisablePopOut)
    }
}
