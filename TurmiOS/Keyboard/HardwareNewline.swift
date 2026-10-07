import TurmCore
import UIKit

enum HardwareNewline {
    static func bytes(for key: UIKey, kittyFlags: Int) -> [UInt8]? {
        guard key.keyCode == .keyboardReturnOrEnter || key.keyCode == .keypadEnter else { return nil }
        let flags = key.modifierFlags
        guard flags.contains(.shift), !flags.contains(.control), !flags.contains(.command) else { return nil }
        return NewlineEncoder.shiftReturn(kittyFlags: kittyFlags, alt: flags.contains(.alternate))
    }
}
