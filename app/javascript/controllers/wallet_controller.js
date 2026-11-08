import { Controller } from "@hotwired/stimulus"
import { connect as connectWallet, onWallet, short, errMsg } from "../par/wallet"

// Header button; also sends the portfolio page to ?owner=<address> once a wallet is connected.
export default class extends Controller {
  static targets = ["button"]

  connect() {
    this.off = onWallet((w) => {
      if (this.hasButtonTarget) this.buttonTarget.textContent = w.address ? short(w.address) : "Connect"
      if (w.address && location.pathname === "/portfolio" && !new URLSearchParams(location.search).get("owner")) {
        window.Turbo.visit(`/portfolio?owner=${w.address}`, { action: "replace" })
      }
    })
  }
  disconnect() { this.off?.() }

  async login() {
    try { await connectWallet() } catch (e) { alertInline(this.hasButtonTarget ? this.buttonTarget : null, errMsg(e)) }
  }
}

function alertInline(el, text) {
  if (!el) return
  el.title = text
  el.classList.add("danger")
  setTimeout(() => el.classList.remove("danger"), 2500)
}
