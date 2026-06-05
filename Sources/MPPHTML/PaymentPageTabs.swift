/// The tab styling and the client tab-switch behavior for a multi-method page,
/// emitted only when a page presents more than one payment method.
enum PaymentPageTabs {
    /// The `<style>` block styling the tab list, tabs, and panels. Referenced via
    /// `--mppx-*` variables like the rest of the page.
    static let style = """
    <style>
      .\(PaymentPageClassNames.tabList) {
        display: flex;
        gap: calc(var(--mppx-spacing-unit) * 2);
        border-bottom: 1px solid var(--mppx-border);
      }
      .\(PaymentPageClassNames.tab) {
        background: none !important;
        border: none !important;
        border-bottom: 1px solid transparent !important;
        border-radius: 0 !important;
        color: var(--mppx-muted) !important;
        cursor: pointer;
        font-size: 0.875rem;
        font-weight: 500;
        margin-bottom: -1px !important;
        padding: calc(var(--mppx-spacing-unit) * 2) calc(var(--mppx-spacing-unit) * 4) !important;
        text-transform: capitalize;
        width: auto !important;
      }
      .\(PaymentPageClassNames.tab)[aria-selected='true'] {
        border-bottom-color: var(--mppx-foreground) !important;
        color: var(--mppx-foreground) !important;
      }
      .\(PaymentPageClassNames.tab):hover:not([aria-selected='true']) {
        color: var(--mppx-foreground) !important;
      }
      .\(PaymentPageClassNames.tabPanel)[hidden] {
        display: none;
      }
    </style>
    """

    /// The tab-switch `<script>`: clicking or arrow-keying a tab selects its panel
    /// and updates the summary (amount, description, expiry) from the tab's
    /// `data-*` attributes, and syncs the choice to the `__mppx_tab` query so a
    /// reload restores it. Ported from the peer's `compose.main`; the expiry
    /// display uses the server-rendered deterministic string (`data-expires-display`)
    /// rather than the browser locale.
    static let script = """
    <script>
      (function () {
        var tablist = document.querySelector('.\(PaymentPageClassNames.tabList)')
        var summary = document.querySelector('.\(PaymentPageClassNames.summary)')
        if (!tablist || !summary) return
        var amount = summary.querySelector('.\(PaymentPageClassNames.summaryAmount)')
        var tabs = Array.prototype.slice.call(tablist.querySelectorAll('[role="tab"]'))
        var slugs = []
        var counts = {}
        tabs.forEach(function (tab) {
          var name = (tab.textContent || '').trim().toLowerCase()
          counts[name] = (counts[name] || 0) + 1
          slugs.push(counts[name] === 1 ? name : name + '-' + counts[name])
        })
        function updateSummary(tab) {
          amount.textContent = tab.dataset.amount
          var desc = summary.querySelector('.\(PaymentPageClassNames.summaryDescription)')
          if (desc) desc.remove()
          if (tab.dataset.description) {
            var p = document.createElement('p')
            p.className = '\(PaymentPageClassNames.summaryDescription)'
            p.textContent = tab.dataset.description
            amount.after(p)
          }
          var exp = summary.querySelector('.\(PaymentPageClassNames.summaryExpires)')
          if (exp) exp.remove()
          if (tab.dataset.expires) {
            var p2 = document.createElement('p')
            p2.className = '\(PaymentPageClassNames.summaryExpires)'
            var time = document.createElement('time')
            time.dateTime = tab.dataset.expires
            time.textContent = tab.dataset.expiresDisplay || tab.dataset.expires
            p2.textContent = (tab.dataset.expiresLabel || '') + ' '
            p2.appendChild(time)
            summary.appendChild(p2)
          }
        }
        function activate(tab, updateUrl) {
          tabs.forEach(function (t) {
            t.setAttribute('aria-selected', 'false')
            t.setAttribute('tabindex', '-1')
          })
          tab.setAttribute('aria-selected', 'true')
          tab.removeAttribute('tabindex')
          tab.focus()
          document.querySelectorAll('[role="tabpanel"]').forEach(function (p) { p.hidden = true })
          document.getElementById(tab.getAttribute('aria-controls')).hidden = false
          updateSummary(tab)
          if (updateUrl !== false) {
            var url = new URL(location.href)
            url.searchParams.set('\(PaymentPageParams.tab)', slugs[tabs.indexOf(tab)])
            history.replaceState(null, '', url)
          }
        }
        var initial = new URL(location.href).searchParams.get('\(PaymentPageParams.tab)')
        if (initial !== null) {
          var index = slugs.indexOf(initial)
          if (index >= 0) activate(tabs[index], false)
        }
        tablist.addEventListener('click', function (event) {
          var tab = event.target.closest('[role="tab"]')
          if (tab) activate(tab)
        })
        tablist.addEventListener('keydown', function (event) {
          var index = tabs.indexOf(event.target)
          if (index < 0) return
          var next
          if (event.key === 'ArrowRight') next = tabs[(index + 1) % tabs.length]
          else if (event.key === 'ArrowLeft') next = tabs[(index - 1 + tabs.length) % tabs.length]
          else if (event.key === 'Home') next = tabs[0]
          else if (event.key === 'End') next = tabs[tabs.length - 1]
          if (next) { event.preventDefault(); activate(next) }
        })
      })()
    </script>
    """
}
