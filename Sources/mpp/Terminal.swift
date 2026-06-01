#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Terminal-attachment probe used to decide whether a payment prompt can be shown and answered.
enum Terminal {
    /// Whether both standard input and standard error are attached to a terminal. A piped,
    /// redirected, or CI run is not interactive, so it cannot show a prompt or read an answer -
    /// the CLI then requires an explicit headless approval mode.
    static var isInteractive: Bool {
        isatty(0) != 0 && isatty(2) != 0
    }
}
