import { Controller } from "@hotwired/stimulus"
import { t } from "../par/i18n"
import { onWallet } from "../par/wallet"

// "You received …" line on a holders-mode token page, for the connected wallet.
export default class extends Controller {
  static targets = ["mine"]
  static values = { url: String }

  connect() {
    this.off = onWallet((w) => this.load(w.address))
  }
  disconnect() { this.off?.() }

  async load(address) {
    if (!address) { this.mineTarget.hidden = true; return }
    try {
      const res = await fetch(`${this.urlValue}&owner=${address}`)
      const j = await res.json()
      const parts = (j.totals || []).map((tot) => `${fmt(Number(BigInt(tot.total)) / 10 ** tot.decimals)} ${tot.symbol}`)
      this.mineTarget.textContent = parts.length
        ? t("rewards.received", { amounts: parts.join(" + "), n: `${j.items.length}${j.items.length >= 500 ? "+" : ""}` })
        : t("rewards.none")
      this.mineTarget.hidden = false
    } catch {
      this.mineTarget.hidden = true
    }
  }
}

function fmt(n) {
  if (n >= 1e9) return (n / 1e9).toFixed(2) + "B"
  if (n >= 1e6) return (n / 1e6).toFixed(2) + "M"
  if (n >= 1e3) return (n / 1e3).toFixed(2) + "K"
  return n.toPrecision(4)
}
