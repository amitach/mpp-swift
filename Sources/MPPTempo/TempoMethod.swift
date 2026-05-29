import MPPCore

/// Shared identity of the Tempo charge method: the `tempo` method name (the intent
/// is `IntentName.charge`). `MethodName` ships no predefined `tempo` constant and
/// its unchecked initializer is package-internal, so this fixed grammar-valid
/// token is built once here and reused by both the client (`TempoProofMethod`) and
/// the server (`TempoProofVerifier`), rather than duplicated.
enum TempoMethod {
    /// The canonical `tempo` method name.
    static let name: MethodName = {
        guard let name = try? MethodName("tempo") else {
            preconditionFailure("tempo is a valid method name")
        }
        return name
    }()
}
