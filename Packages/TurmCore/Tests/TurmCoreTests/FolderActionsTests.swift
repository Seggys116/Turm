import Testing
@testable import TurmCore

struct FolderActionsTests {
    @Test func theWorkingDirectoryDoesNotOfferCd() {
        #expect(!FolderActions.offersChangeDirectory(folder: "/home/zak", workingDirectory: "/home/zak"))
        #expect(!FolderActions.offersChangeDirectory(folder: "/home/zak/", workingDirectory: "/home/zak"))
        #expect(!FolderActions.offersChangeDirectory(folder: "/", workingDirectory: "/"))
    }

    @Test func anotherFolderOffersCd() {
        #expect(FolderActions.offersChangeDirectory(folder: "/home/zak/src", workingDirectory: "/home/zak"))
        #expect(!FolderActions.offersChangeDirectory(folder: "", workingDirectory: "/home/zak"))
    }

    @Test func aFolderOffersFilesOnEitherKindOfConnection() {
        #expect(FolderActions.offersFiles(folder: "/home/zak"))
        #expect(FolderActions.offersFiles(folder: "/Users/zak/Projects"))
        #expect(FolderActions.offersFiles(folder: "/"))
        #expect(!FolderActions.offersFiles(folder: ""))
    }
}
