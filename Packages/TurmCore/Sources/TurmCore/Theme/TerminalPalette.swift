public nonisolated struct PaletteColor: Equatable, Sendable {
    public let light: UInt32
    public let dark: UInt32

    public init(light: UInt32, dark: UInt32) {
        self.light = light
        self.dark = dark
    }

    public func hex(dark isDark: Bool) -> UInt32 {
        isDark ? dark : light
    }

    public func components(dark isDark: Bool) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let value = hex(dark: isDark)
        return (UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF))
    }
}

public nonisolated enum TerminalPalette {
    public static let background = PaletteColor(light: 0xFFFFFF, dark: 0x0B0B0C)
    public static let foreground = PaletteColor(light: 0x1F2328, dark: 0xDCDCDC)
    public static let cursor = PaletteColor(light: 0x1F2328, dark: 0xDCDCDC)
    public static let selection = PaletteColor(light: 0xB4D5FE, dark: 0x2E4A6E)

    public static let ansi: [PaletteColor] = [
        PaletteColor(light: 0x24292F, dark: 0x1D1F21), PaletteColor(light: 0xCF222E, dark: 0xF26D78),
        PaletteColor(light: 0x1A7F37, dark: 0x8FD46D), PaletteColor(light: 0x9A6700, dark: 0xE6C547),
        PaletteColor(light: 0x0969DA, dark: 0x61AFEF), PaletteColor(light: 0x8250DF, dark: 0xC678DD),
        PaletteColor(light: 0x1B7C83, dark: 0x56B6C2), PaletteColor(light: 0x6E7781, dark: 0xC8CCD4),
        PaletteColor(light: 0x57606A, dark: 0x5C6370), PaletteColor(light: 0xA40E26, dark: 0xFF8B94),
        PaletteColor(light: 0x2DA44E, dark: 0xB5F08E), PaletteColor(light: 0xBF8700, dark: 0xF5DB7A),
        PaletteColor(light: 0x218BFF, dark: 0x82C4FF), PaletteColor(light: 0xA475F9, dark: 0xDD9AF0),
        PaletteColor(light: 0x3192AA, dark: 0x7AD5E0), PaletteColor(light: 0x8C959F, dark: 0xFFFFFF),
    ]
}
