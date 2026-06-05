/// A fully resolved theme: every default filled in, ready for the renderer and
/// for the embedded data block. Distinct from ``PaymentPageTheme`` so the
/// renderer never handles an unresolved (optional) value.
///
/// `Encodable` deliberately omits `fontURL`, `favicon`, and `logo`: those drive
/// `<link>`/`<img>` tags in the page head, not the JSON theme a method script
/// reads, matching the peer's embedded `theme` shape exactly.
struct ResolvedTheme {
    let colorScheme: String
    let fontFamily: String
    let fontSizeBase: String
    let radius: String
    let spacingUnit: String
    let accent: LightDarkColor
    let background: LightDarkColor
    let border: LightDarkColor
    let foreground: LightDarkColor
    let muted: LightDarkColor
    let negative: LightDarkColor
    let positive: LightDarkColor
    let surface: LightDarkColor

    // Head-only assets, not part of the encoded theme.
    let fontURL: String?
    let favicon: LightDarkAsset?
    let logo: LightDarkAsset?
}

extension ResolvedTheme: Encodable {
    /// Only the tokens a method script consumes; the head-only assets above are
    /// intentionally absent.
    enum CodingKeys: String, CodingKey {
        case colorScheme, fontFamily, fontSizeBase, radius, spacingUnit
        case accent, background, border, foreground, muted, negative, positive, surface
    }
}

extension PaymentPageTheme {
    enum Defaults {
        static let colorScheme = "light dark"
        static let fontFamily = "system-ui, -apple-system, sans-serif"
        static let fontSizeBase = "16px"
        static let radius = "6px"
        static let spacingUnit = "2px"
        static let accent = LightDarkColor.pair(light: "#171717", dark: "#ededed")
        static let background = LightDarkColor.pair(light: "#ffffff", dark: "#0a0a0a")
        static let border = LightDarkColor.pair(light: "#e5e5e5", dark: "#2e2e2e")
        static let foreground = LightDarkColor.pair(light: "#0a0a0a", dark: "#ededed")
        static let muted = LightDarkColor.pair(light: "#666666", dark: "#a1a1a1")
        static let negative = LightDarkColor.both("#e5484d")
        static let positive = LightDarkColor.both("#30a46c")
        static let surface = LightDarkColor.pair(light: "#f5f5f5", dark: "#1a1a1a")
    }

    /// Fills every default. A scalar string override is honored only when
    /// non-empty (matching the peer's `mergeDefined`); a color override replaces
    /// the default outright; `fontURL` is kept only when non-empty.
    func resolved() -> ResolvedTheme {
        ResolvedTheme(
            colorScheme: colorScheme?.rawValue ?? Defaults.colorScheme,
            fontFamily: pick(fontFamily, Defaults.fontFamily),
            fontSizeBase: pick(fontSizeBase, Defaults.fontSizeBase),
            radius: pick(radius, Defaults.radius),
            spacingUnit: pick(spacingUnit, Defaults.spacingUnit),
            accent: accent ?? Defaults.accent,
            background: background ?? Defaults.background,
            border: border ?? Defaults.border,
            foreground: foreground ?? Defaults.foreground,
            muted: muted ?? Defaults.muted,
            negative: negative ?? Defaults.negative,
            positive: positive ?? Defaults.positive,
            surface: surface ?? Defaults.surface,
            fontURL: nonEmpty(fontURL),
            favicon: favicon,
            logo: logo
        )
    }

    private func pick(_ override: String?, _ fallback: String) -> String {
        guard let override, !override.isEmpty else { return fallback }
        return override
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
