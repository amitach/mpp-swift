/// A color that may differ between light and dark schemes. A single value
/// applies to both; a pair gives an explicit `(light, dark)`. String literals
/// construct the single-value form, so `accent: "#0099ff"` reads naturally.
public enum LightDarkColor: Sendable, Equatable {
    /// One color for both schemes.
    case both(String)
    /// Distinct `(light, dark)` colors.
    case pair(light: String, dark: String)

    /// The light-scheme color.
    public var light: String {
        switch self {
        case let .both(value): value
        case let .pair(light, _): light
        }
    }

    /// The dark-scheme color.
    public var dark: String {
        switch self {
        case let .both(value): value
        case let .pair(_, dark): dark
        }
    }
}

extension LightDarkColor: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .both(value)
    }
}

extension LightDarkColor: Encodable {
    /// Encodes as a bare string for ``both`` (the value applies to both schemes)
    /// or a two-element `[light, dark]` array for ``pair``, matching the peer's
    /// embedded theme shape.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .both(value): try container.encode(value)
        case let .pair(light, dark): try container.encode([light, dark])
        }
    }
}

/// A URL-valued theme asset (logo or favicon) that may differ between schemes.
public enum LightDarkAsset: Sendable, Equatable {
    /// One URL for both schemes.
    case single(String)
    /// Distinct `(light, dark)` URLs.
    case pair(light: String, dark: String)
}

extension LightDarkAsset: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .single(value)
    }
}

/// The page color scheme: light only, dark only, or both (the default, which
/// emits dark colors under `@media (prefers-color-scheme: dark)`).
public enum PaymentPageColorScheme: String, Sendable {
    case light
    case dark
    case lightDark = "light dark"
}

/// The visual theme of a payment page. Every field is optional; an omitted (or
/// empty) value falls back to a neutral default. Colors accept either one value
/// for both schemes or an explicit `(light, dark)` pair.
public struct PaymentPageTheme: Sendable {
    /// Light, dark, or both. Default `light dark`.
    public var colorScheme: PaymentPageColorScheme?
    /// CSS `font-family`. Default `system-ui, -apple-system, sans-serif`.
    public var fontFamily: String?
    /// Base font size. Default `16px`.
    public var fontSizeBase: String?
    /// A stylesheet URL to inject (e.g. a Google Fonts `<link>`).
    public var fontURL: String?
    /// Favicon URL, optionally per scheme. Falls back to the realm host's
    /// favicon via Google's S2 service when omitted.
    public var favicon: LightDarkAsset?
    /// Header logo URL, optionally per scheme. No logo when omitted.
    public var logo: LightDarkAsset?
    /// CSS `border-radius`. Default `6px`.
    public var radius: String?
    /// Base spacing unit all spacing derives from. Default `2px`.
    public var spacingUnit: String?

    /// Accent color (buttons, links, focus ring). Default `#171717` / `#ededed`.
    public var accent: LightDarkColor?
    /// Page background. Default `#ffffff` / `#0a0a0a`.
    public var background: LightDarkColor?
    /// Border color. Default `#e5e5e5` / `#2e2e2e`.
    public var border: LightDarkColor?
    /// Primary text color. Default `#0a0a0a` / `#ededed`.
    public var foreground: LightDarkColor?
    /// Secondary/muted text. Default `#666666` / `#a1a1a1`.
    public var muted: LightDarkColor?
    /// Error/danger color. Default `#e5484d`.
    public var negative: LightDarkColor?
    /// Success color. Default `#30a46c`.
    public var positive: LightDarkColor?
    /// Card/surface color. Default `#f5f5f5` / `#1a1a1a`.
    public var surface: LightDarkColor?

    public init(
        colorScheme: PaymentPageColorScheme? = nil,
        fontFamily: String? = nil,
        fontSizeBase: String? = nil,
        fontURL: String? = nil,
        favicon: LightDarkAsset? = nil,
        logo: LightDarkAsset? = nil,
        radius: String? = nil,
        spacingUnit: String? = nil,
        accent: LightDarkColor? = nil,
        background: LightDarkColor? = nil,
        border: LightDarkColor? = nil,
        foreground: LightDarkColor? = nil,
        muted: LightDarkColor? = nil,
        negative: LightDarkColor? = nil,
        positive: LightDarkColor? = nil,
        surface: LightDarkColor? = nil
    ) {
        self.colorScheme = colorScheme
        self.fontFamily = fontFamily
        self.fontSizeBase = fontSizeBase
        self.fontURL = fontURL
        self.favicon = favicon
        self.logo = logo
        self.radius = radius
        self.spacingUnit = spacingUnit
        self.accent = accent
        self.background = background
        self.border = border
        self.foreground = foreground
        self.muted = muted
        self.negative = negative
        self.positive = positive
        self.surface = surface
    }
}
