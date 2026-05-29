import Foundation

/// Builds a ``SecretStore`` from the runtime environment, the spec security
/// guidance's recommended delivery mechanism for the server secret: a secrets
/// manager is the source of truth and injects the value into the environment, and
/// this reads it. The environment is passed in (for example
/// `ProcessInfo.processInfo.environment` at the application entry point) rather
/// than read from the process here, so the loader stays testable and has no hidden
/// global dependency.
///
/// ``currentVariable`` (`MPP_SECRET_KEY`) holds the current signing key and is
/// required. ``previousVariable`` (`MPP_SECRET_KEY_PREVIOUS`) is an optional
/// comma-separated list of previous keys still in their rotation overlap window
/// (an mpp-swift extension, delivered the same way; the reference SDKs read only a
/// single key). Each key is the variable value's UTF-8 bytes, matching how the
/// HMAC key is derived everywhere else, then validated by ``SecretStore``.
public enum EnvironmentSecretLoader {
    /// The environment variable holding the current signing secret.
    public static let currentVariable = "MPP_SECRET_KEY"
    /// The environment variable holding comma-separated previous (overlap) secrets.
    public static let previousVariable = "MPP_SECRET_KEY_PREVIOUS"

    /// Builds a ``SecretStore`` from `environment`.
    ///
    /// - Throws: ``LoadError/missingSecret(variable:)`` if `MPP_SECRET_KEY` is
    ///   absent or empty, or ``LoadError/invalid(_:)`` wrapping a
    ///   ``SecretStore/ValidationError`` if a key is too short or there are too many
    ///   previous keys.
    public static func load(from environment: [String: String]) throws(LoadError) -> SecretStore {
        guard let currentValue = environment[currentVariable], !currentValue.isEmpty else {
            throw .missingSecret(variable: currentVariable)
        }
        let previous: [Data] = (environment[previousVariable] ?? "")
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { Data($0.utf8) }
        do {
            return try SecretStore(current: Data(currentValue.utf8), previous: previous)
        } catch {
            throw .invalid(error)
        }
    }

    /// A reason the environment could not be loaded into a ``SecretStore``.
    public enum LoadError: Error, Sendable, Hashable {
        /// The required current-secret variable was absent or empty.
        case missingSecret(variable: String)
        /// A loaded secret failed ``SecretStore`` validation.
        case invalid(SecretStore.ValidationError)
    }
}
