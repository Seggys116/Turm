import Foundation

public nonisolated struct KeyModifiers: OptionSet, Sendable {
    // Raw values are the xterm modifier bits, so the escape parameter is 1 plus the raw value.
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let alt = KeyModifiers(rawValue: 2)
    public static let ctrl = KeyModifiers(rawValue: 4)

    public var parameter: Int { 1 + Int(rawValue) }
}

public nonisolated enum Arrow: CaseIterable, Hashable, Sendable {
    case up
    case down
    case right
    case left

    public var final: UInt8 {
        switch self {
        case .up: 0x41
        case .down: 0x42
        case .right: 0x43
        case .left: 0x44
        }
    }
}

public nonisolated enum Navigation: Hashable, Sendable {
    case home
    case end
    case pageUp
    case pageDown
}

public nonisolated enum KeyKind: Hashable, Sendable {
    case escape
    case tab
    case newline
    case control
    case alt
    case arrow(Arrow)
    case navigation(Navigation)
    case text(String)
    case function(Int)
    case paste
    case pad
    case functionPage
    case hideKeyboard
}

public nonisolated struct TerminalKey: Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: KeyKind
    public let name: String
    public var label = ""
    public var symbol: String?

    public init(id: String, kind: KeyKind, name: String, label: String = "", symbol: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.label = label
        self.symbol = symbol
    }

    public static let symbolNames: [(character: String, name: String)] = [
        ("|", "Pipe"), ("~", "Tilde"), ("/", "Slash"), ("-", "Hyphen"), ("_", "Underscore"),
        (":", "Colon"), (";", "Semicolon"), ("`", "Backtick"), ("'", "Apostrophe"), ("\"", "Double quote"),
        ("$", "Dollar"), ("&", "Ampersand"), ("*", "Asterisk"), ("<", "Less than"), (">", "Greater than"),
        ("{", "Left brace"), ("}", "Right brace"), ("[", "Left bracket"), ("]", "Right bracket"),
    ]

    public static let catalog: [TerminalKey] = [
        TerminalKey(id: "esc", kind: .escape, name: "Escape", label: "esc"),
        TerminalKey(id: "tab", kind: .tab, name: "Tab", label: "tab"),
        TerminalKey(id: "newline", kind: .newline, name: "Newline", symbol: "return"),
        TerminalKey(id: "ctrl", kind: .control, name: "Control", label: "ctrl"),
        TerminalKey(id: "alt", kind: .alt, name: "Alt", label: "alt"),
        TerminalKey(id: "left", kind: .arrow(.left), name: "Left arrow", symbol: "arrow.left"),
        TerminalKey(id: "down", kind: .arrow(.down), name: "Down arrow", symbol: "arrow.down"),
        TerminalKey(id: "up", kind: .arrow(.up), name: "Up arrow", symbol: "arrow.up"),
        TerminalKey(id: "right", kind: .arrow(.right), name: "Right arrow", symbol: "arrow.right"),
        TerminalKey(id: "pad", kind: .pad, name: "Drag pad", symbol: "arrow.up.and.down.and.arrow.left.and.right"),
        TerminalKey(id: "home", kind: .navigation(.home), name: "Home", label: "home"),
        TerminalKey(id: "end", kind: .navigation(.end), name: "End", label: "end"),
        TerminalKey(id: "pgup", kind: .navigation(.pageUp), name: "Page up", label: "pgup"),
        TerminalKey(id: "pgdn", kind: .navigation(.pageDown), name: "Page down", label: "pgdn"),
    ] + symbolNames.map { TerminalKey(id: "sym:" + $0.character, kind: .text($0.character), name: $0.name, label: $0.character) } + [
        TerminalKey(id: "paste", kind: .paste, name: "Paste", symbol: "doc.on.clipboard"),
    ]

    public static let functionKeys: [TerminalKey] = (1...12).map {
        TerminalKey(id: "f\($0)", kind: .function($0), name: "F\($0)", label: "F\($0)")
    }

    public static let defaultIDs: [String] = [
        "esc", "tab", "newline", "ctrl", "alt", "left", "down", "up", "right", "pad", "home", "end", "pgup", "pgdn",
    ] + symbolNames.map { "sym:" + $0.character } + ["paste"]

    private static let lookup = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })

    public static func key(withID id: String) -> TerminalKey? {
        lookup[id]
    }

    public var isModifier: Bool {
        kind == .control || kind == .alt
    }
}
