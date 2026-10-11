import Foundation
import Testing
@testable import TurmCore

struct CompanionFileTests {

    @Test func cappedTextUnderLimitIsUnchangedAndNotTruncated() {
        let text = "hello world"
        let (result, truncated) = CompanionFileLimits.cappedText(text, limit: 100)
        #expect(result == text)
        #expect(!truncated)
    }

    @Test func cappedTextOverLimitIsTruncatedAndValidUTF8() {
        let text = "café au lait"
        let limit = 4
        let (result, truncated) = CompanionFileLimits.cappedText(text, limit: limit)
        #expect(truncated)
        #expect(result.utf8.count <= limit)
        #expect(String(bytes: Array(result.utf8), encoding: .utf8) != nil)
    }

    @Test func cappedDataOverMaxReadIsTruncatedToMaxRead() {
        let large = Data(repeating: 0xFF, count: CompanionFileLimits.maxRead + 100)
        let (result, truncated) = CompanionFileLimits.cappedData(large, limit: CompanionFileLimits.maxRead)
        #expect(truncated)
        #expect(result.count == CompanionFileLimits.maxRead)
    }

    @Test func cappedDataUnderLimitIsUnchanged() {
        let small = Data(repeating: 0xAB, count: 10)
        let (result, truncated) = CompanionFileLimits.cappedData(small, limit: CompanionFileLimits.maxRead)
        #expect(!truncated)
        #expect(result == small)
    }

    @Test func decideAllowsSafeWrite() {
        let decision = CompanionWrites.decide(
            uploadsEnabled: true, path: "/proj/a.txt",
            allowedRoot: "/proj", overwrite: false, exists: false
        )
        #expect(decision == .allow(path: "/proj/a.txt"))
    }

    @Test func decideRefusesWhenUploadsDisabled() {
        let decision = CompanionWrites.decide(
            uploadsEnabled: false, path: "/proj/a.txt",
            allowedRoot: "/proj", overwrite: false, exists: false
        )
        guard case .refuse(let reason) = decision else {
            Issue.record("expected .refuse, got \(decision)")
            return
        }
        #expect(reason.contains("disabled") || reason.contains("off") || reason.contains("upload"))
    }

    @Test func decideRefusesPathTraversal() {
        let decision = CompanionWrites.decide(
            uploadsEnabled: true, path: "/proj/../../etc/passwd",
            allowedRoot: "/proj", overwrite: false, exists: false
        )
        guard case .refuse = decision else {
            Issue.record("expected .refuse for traversal, got \(decision)")
            return
        }
    }

    @Test func decideRefusesStringPrefixConfusion() {
        let decision = CompanionWrites.decide(
            uploadsEnabled: true, path: "/project/a",
            allowedRoot: "/proj", overwrite: false, exists: false
        )
        guard case .refuse = decision else {
            Issue.record("expected .refuse for /project/a with root /proj, got \(decision)")
            return
        }
    }

    @Test func decideRefusesExistingFileWithoutOverwriteAndAllowsWithOverwrite() {
        let refuse = CompanionWrites.decide(
            uploadsEnabled: true, path: "/proj/a.txt",
            allowedRoot: "/proj", overwrite: false, exists: true
        )
        guard case .refuse(let reason) = refuse else {
            Issue.record("expected .refuse when exists and overwrite is false, got \(refuse)")
            return
        }
        #expect(reason.contains("exists"))

        let allow = CompanionWrites.decide(
            uploadsEnabled: true, path: "/proj/a.txt",
            allowedRoot: "/proj", overwrite: true, exists: true
        )
        #expect(allow == .allow(path: "/proj/a.txt"))
    }

    @Test func decideRefusesRelativePathAndNullBytePath() {
        let relative = CompanionWrites.decide(
            uploadsEnabled: true, path: "proj/a",
            allowedRoot: "/proj", overwrite: false, exists: false
        )
        guard case .refuse = relative else {
            Issue.record("expected .refuse for relative path, got \(relative)")
            return
        }

        let nullByte = CompanionWrites.decide(
            uploadsEnabled: true, path: "/proj/a\0.txt",
            allowedRoot: "/proj", overwrite: false, exists: false
        )
        guard case .refuse = nullByte else {
            Issue.record("expected .refuse for null-byte path, got \(nullByte)")
            return
        }
    }

    @Test func decideNormalizesDotsAndAllows() {
        let decision = CompanionWrites.decide(
            uploadsEnabled: true, path: "/proj/./sub/../a",
            allowedRoot: "/proj", overwrite: false, exists: false
        )
        #expect(decision == .allow(path: "/proj/a"))
    }
}
