/// A slimmed-down Tailwind preflight (CSS reset), ported verbatim from the peer
/// so a payment page renders identically across implementations. Static except
/// for the single `--mppx-border` reference, which the theme block defines.
///
/// Source: https://github.com/tailwindlabs/tailwindcss preflight.css
enum PaymentPagePreflight {
    static let style = """
    <style>
      *,
      ::after,
      ::before,
      ::backdrop,
      ::file-selector-button {
        box-sizing: border-box;
        margin: 0;
        padding: 0;
        border: 0 solid;
        border-color: var(--mppx-border);
      }
      html,
      :host {
        line-height: 1.5;
        -webkit-text-size-adjust: 100%;
        tab-size: 4;
        -webkit-tap-highlight-color: transparent;
      }
      h1,
      h2,
      h3,
      h4,
      h5,
      h6 {
        font-size: inherit;
        font-weight: inherit;
      }
      a {
        color: inherit;
        -webkit-text-decoration: inherit;
        text-decoration: inherit;
      }
      b,
      strong {
        font-weight: bolder;
      }
      code,
      kbd,
      samp,
      pre {
        font-family:
          ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, 'Liberation Mono', 'Courier New',
          monospace;
        font-size: 1em;
      }
      small {
        font-size: 80%;
      }
      ol,
      ul,
      menu {
        list-style: none;
      }
      img,
      svg,
      video,
      canvas,
      audio,
      iframe,
      embed,
      object {
        display: block;
        vertical-align: middle;
      }
      img,
      video {
        max-width: 100%;
        height: auto;
      }
      button,
      input,
      select,
      optgroup,
      textarea,
      ::file-selector-button {
        font: inherit;
        font-feature-settings: inherit;
        font-variation-settings: inherit;
        letter-spacing: inherit;
        color: inherit;
        border-radius: 0;
        background-color: transparent;
        opacity: 1;
      }
      ::file-selector-button {
        margin-inline-end: 4px;
      }
      ::placeholder {
        opacity: 1;
      }
      @supports (not (-webkit-appearance: -apple-pay-button)) or (contain-intrinsic-size: 1px) {
        ::placeholder {
          color: color-mix(in oklab, currentcolor 50%, transparent);
        }
      }
      textarea {
        resize: vertical;
      }
      ::-webkit-search-decoration {
        -webkit-appearance: none;
      }
      :-moz-ui-invalid {
        box-shadow: none;
      }
      button,
      input:where([type='button'], [type='reset'], [type='submit']),
      ::file-selector-button {
        appearance: button;
      }
      ::-webkit-inner-spin-button,
      ::-webkit-outer-spin-button {
        height: auto;
      }
      [hidden]:where(:not([hidden='until-found'])) {
        display: none !important;
      }
    </style>
    """
}
