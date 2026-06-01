import Foundation

/// Strips terminal control characters (ANSI escape sequences, CR / LF, DEL, other C0 / C1 controls,
/// and format characters) from a server-controlled string before it is shown in a terminal prompt
/// or an authentication dialog.
///
/// The challenge fields surfaced for confirmation - `description`, `recipient`, `realm`, `currency`
/// - come from the (untrusted) payment server. Interpolated raw into a terminal prompt, a crafted
/// value could rewrite or spoof the confirmation line (hide or misstate the amount, fake the
/// `[y/N]`) and trick the operator into approving. Stripping the control characters neutralizes
/// that: the value can only ever appear as inert literal text. `maxLength`, when given, also bounds
/// a flooding attempt by truncating with a trailing ellipsis.
func displaySafe(_ value: String, maxLength: Int? = nil) -> String {
    let controls = CharacterSet.controlCharacters
    let scalars = value.unicodeScalars.filter { !controls.contains($0) }
    var safe = String(String.UnicodeScalarView(scalars))
    if let maxLength, safe.count > maxLength {
        safe = String(safe.prefix(maxLength)) + "\u{2026}"
    }
    return safe
}
