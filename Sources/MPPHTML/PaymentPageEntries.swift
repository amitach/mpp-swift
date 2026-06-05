import MPPCore

// The multi-method building blocks of a payment page: the tab list, the panels,
// and the per-entry content scripts. Internal (not private) so `render` in the
// main file can reach them across the file split.
extension PaymentPage {
    /// The tab list: one `role="tab"` button per method, the first selected. Each
    /// tab carries the method's amount/description/expiry in `data-*` attributes
    /// so the tab script can update the summary on switch. Empty for a single
    /// method.
    static func tabList(
        _ entries: [PaymentPageEntry],
        text: ResolvedText,
        hasTabs: Bool
    ) -> String {
        guard hasTabs else { return "" }
        let buttons = entries.enumerated()
            .map { tabButton($1, index: $0, text: text) }
            .joined(separator: "\n            ")
        return "<nav class=\"\(PaymentPageClassNames.tabList)\" role=\"tablist\" "
            + "aria-label=\"Payment methods\">\(buttons)</nav>"
    }

    private static func tabButton(
        _ entry: PaymentPageEntry, index: Int, text: ResolvedText
    ) -> String {
        let label = entry.method.label ?? entry.challenge.method.rawValue
        var data = "data-amount=\"\(sanitizeHTML(entry.formattedAmount))\""
        if let description = entry.challenge.description {
            data += " data-description=\"\(sanitizeHTML(description))\""
        }
        if let expires = entry.challenge.expires {
            let (datetime, display) = expiryParts(expires)
            data += " data-expires=\"\(datetime)\""
                + " data-expires-display=\"\(sanitizeHTML(display))\""
                + " data-expires-label=\"\(sanitizeHTML(text.expires))\""
        }
        let selected = index == 0 ? "true" : "false"
        let tabindex = index == 0 ? "" : " tabindex=\"-1\""
        return "<button class=\"\(PaymentPageClassNames.tab)\" role=\"tab\" "
            + "id=\"mppx-tab-\(index)\" "
            + "aria-selected=\"\(selected)\" aria-controls=\"mppx-panel-\(index)\"\(tabindex) "
            + "\(data)>\(sanitizeHTML(label))</button>"
    }

    /// The form mount(s): a single `#root` for one method, or one hidden-by-default
    /// `role="tabpanel"` per method (the first shown), each wrapping a `#root-{i}`.
    static func panels(_ entries: [PaymentPageEntry], hasTabs: Bool) -> String {
        guard hasTabs else {
            return "<div id=\"\(PaymentPageIDs.root)\" aria-label=\"Payment form\"></div>"
        }
        return entries.indices
            .map { index in
                let hidden = index == 0 ? "" : " hidden"
                return "<div class=\"\(PaymentPageClassNames.tabPanel)\" role=\"tabpanel\" "
                    + "id=\"mppx-panel-\(index)\" aria-labelledby=\"mppx-tab-\(index)\"\(hidden)>"
                    + "<div id=\"\(PaymentPageIDs.root)-\(index)\" aria-label=\"Payment form\">"
                    + "</div></div>"
            }
            .joined(separator: "\n          ")
    }

    /// Each method's content script. On a multi-method page the script's opening
    /// `<script>` gains a `data-mppx-challenge-id` so the method can find its own
    /// entry in the data map; a single method's content is emitted verbatim.
    static func contentScripts(_ entries: [PaymentPageEntry], hasTabs: Bool) -> String {
        guard hasTabs else { return entries[0].method.content }
        return entries
            .map { bindChallenge($0.method.content, to: $0.challenge.id) }
            .joined(separator: "\n")
    }

    /// Inserts `data-mppx-challenge-id` into the first `<script` opening tag of a
    /// method's content, tolerating any attributes (`<script>`,
    /// `<script type="module">`, `<script defer>`), so the binding is not silently
    /// skipped for a non-bare tag. Content with no `<script` opening tag is
    /// emitted unchanged. Only the first tag is bound (a method contributes one
    /// mounting script).
    private static func bindChallenge(_ content: String, to challengeID: String) -> String {
        guard let range = content.range(of: "<script") else { return content }
        let attr = " \(PaymentPageAttrs.challengeID)=\"\(sanitizeHTML(challengeID))\""
        return content.replacingCharacters(in: range.upperBound ..< range.upperBound, with: attr)
    }
}
