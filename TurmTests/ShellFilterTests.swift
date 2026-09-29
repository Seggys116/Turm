import Testing
@testable import Turm

struct ShellFilterTests {
    private let fields = ["~/Projects/Turm", "swift build", "main"]

    @Test func emptyQueryMatchesEverything() {
        #expect(ShellFilter.matches("", fields: fields))
        #expect(ShellFilter.matches("   ", fields: []))
    }

    @Test(arguments: ["turm", "SWIFT", "projects build", "  main "])
    func matchesAcrossFieldsCaseInsensitively(query: String) {
        #expect(ShellFilter.matches(query, fields: fields))
    }

    @Test(arguments: ["docker", "swift docker"])
    func everyTermMustMatch(query: String) {
        #expect(!ShellFilter.matches(query, fields: fields))
    }
}
