import MPPCore

extension JSONValue {
    /// The wrapped string when this is a `.string`, else `nil`. Shared by the Tempo
    /// proof and session payload parsers (one home, not a per-file copy).
    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }
}
