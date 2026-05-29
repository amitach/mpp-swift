import Foundation

/// Builds a ``SecretStore`` from secret files on disk: the delivery mechanism for
/// deployments that mount secrets as files (a Kubernetes `Secret` volume, Docker
/// secrets under `/run/secrets`, ...) instead of injecting them into the
/// environment. Like ``EnvironmentSecretLoader`` it implements the spec security
/// guidance's model where a managed secret store is the source of truth and
/// injects the value into the process; here the injection point is a file path the
/// caller passes in, so the loader stays testable and has no hidden global state.
///
/// Each file holds the secret's exact bytes (the file contents are used as the
/// HMAC key verbatim, with no trimming). A file written from a text secret must
/// therefore contain no trailing newline, so the same secret loads identically
/// whether delivered through a file or through ``EnvironmentSecretLoader`` (which
/// uses the variable value's UTF-8 bytes); a file may equally hold a raw binary
/// key. The operator should restrict the files' permissions (the loader does not
/// enforce a mode, since mounted-secret files vary by platform).
///
/// The current-key file is required; any previous-key files are earlier keys still
/// in their rotation overlap window, most-recent first (an mpp-swift extension
/// delivered the same way; the reference SDKs read a single key). The bytes are
/// validated by ``SecretStore``.
public enum FileSecretLoader {
    /// Builds a ``SecretStore`` from secret files.
    ///
    /// - Parameters:
    ///   - currentPath: Path to the file holding the current signing key.
    ///   - previousPaths: Paths to files holding previous (overlap-window) keys,
    ///     most-recent first. Defaults to none.
    /// - Throws: ``LoadError/unreadable(path:)`` if a file is absent or cannot be
    ///   read, or ``LoadError/invalid(_:)`` wrapping a ``SecretStore/ValidationError``
    ///   if a key is too short or there are too many previous keys.
    public static func load(
        currentPath: String,
        previousPaths: [String] = []
    ) throws(LoadError) -> SecretStore {
        let current = try readSecret(atPath: currentPath)
        let previous = try previousPaths.map { path throws(LoadError) in
            try readSecret(atPath: path)
        }
        do {
            return try SecretStore(current: current, previous: previous)
        } catch {
            throw .invalid(error)
        }
    }

    private static func readSecret(atPath path: String) throws(LoadError) -> Data {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw .unreadable(path: path)
        }
        return data
    }

    /// A reason the secret files could not be loaded into a ``SecretStore``.
    public enum LoadError: Error, Sendable, Hashable {
        /// A secret file was absent or could not be read.
        case unreadable(path: String)
        /// A loaded secret failed ``SecretStore`` validation.
        case invalid(SecretStore.ValidationError)
    }
}
