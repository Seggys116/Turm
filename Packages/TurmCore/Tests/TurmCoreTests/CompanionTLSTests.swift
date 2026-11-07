import Testing
@testable import TurmCore

struct CompanionTLSTests {
    @Test func onlyTheForwardSecretSuiteIsOffered() {
        #expect(CompanionTLS.preferredSuites == [CompanionTLS.forwardSecretSuite])
        #expect(CompanionTLS.forwardSecretSuite == 0xCCAC)
    }
}
