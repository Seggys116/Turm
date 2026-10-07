import Foundation

public nonisolated enum NewlineEncoder {
    private static let escape: UInt8 = 0x1B
    private static let carriageReturn: UInt8 = 0x0D
    // disambiguate (1) and report-all-keys (8) are the kitty flags that move Return to CSI u
    private static let escapeFlags = 9

    public static func shiftReturn(kittyFlags: Int, alt: Bool = false) -> [UInt8] {
        if kittyFlags & escapeFlags != 0 {
            let parameter = alt ? 4 : 2
            return [escape, 0x5B] + Array("13;\(parameter)u".utf8)
        }
        return alt ? [escape, carriageReturn] : [carriageReturn]
    }

    public static func insertNewline(kittyFlags: Int) -> [UInt8] {
        kittyFlags & escapeFlags != 0 ? shiftReturn(kittyFlags: kittyFlags) : [escape, carriageReturn]
    }
}
