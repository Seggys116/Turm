import Foundation

final class KittyStore {
    var images: [InlineImage] = []
    var virtualPlacements: [InlineImage] = []
    var sources: [UInt32: KittyAnimation] = [:]
    var imageNumbers: [UInt32: UInt32] = [:]
    var nextImageID: UInt32 = 1
    var nextInternalID: UInt32 = 4_290_000_000
    var unloaded: Set<UInt32> = []
    var accessClock: UInt64 = 0
    var engineIDs: [UInt32: UInt32] = [:]
    var storageLimit = 320 * 1024 * 1024
}
