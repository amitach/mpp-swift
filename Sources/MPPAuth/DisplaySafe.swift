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
///
/// Removed: C0 / C1 controls and format characters (ANSI escapes, CR / LF, DEL) AND the Unicode
/// bidirectional formatting characters explicitly (LRM / RLM, the LRE..RLO embeddings/overrides,
/// PDF, and the LRI..PDI isolates). The bidi set is filtered by code point rather than relying on
/// `CharacterSet` category membership, so a "Trojan Source" style visual reordering of the payee or
/// amount cannot slip through even if the category set changes.
func displaySafe(_ value: String, maxLength: Int? = nil) -> String {
    let controls = CharacterSet.controlCharacters
    let bidi: Set<Unicode.Scalar> = [
        "\u{200E}", "\u{200F}", // LRM, RLM
        "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}", // LRE, RLE, PDF, LRO, RLO
        "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}", // LRI, RLI, FSI, PDI
    ]
    let scalars = value.unicodeScalars.filter { !controls.contains($0) && !bidi.contains($0) }
    var safe = String(String.UnicodeScalarView(scalars))
    if let maxLength, safe.count > maxLength {
        safe = String(safe.prefix(maxLength)) + "\u{2026}"
    }
    return safe
}
