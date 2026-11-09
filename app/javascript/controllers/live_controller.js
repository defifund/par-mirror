import { Controller } from "@hotwired/stimulus"
import { t } from "../par/i18n"

// Keeps a page current while history keeps being indexed, without holding a server connection:
// polls the cheap /idx/<chain>/pulse endpoint every few seconds (paused while the tab is hidden).
//   token page:  when this token traded, re-fetches the page and swaps every [data-live] block
//                in place (stats, trades, holders, burns, tab counts); new trade rows flash.
//   explore:     counts new launches and trades and offers a one-click refresh of the list.
export default class extends Controller {
  static values = { cursors: Object, token: String, trades: Boolean, every: { type: Number, default: 5000 } }
  static targets = ["dot", "banner", "bannerText", "bannerLink"]

  connect() {
    this.cursors = { ...this.cursorsValue }
    this.newLaunches = 0
    this.newTrades = 0
    this.onVisible = () => { if (!document.hidden) this.tick() }
    document.addEventListener("visibilitychange", this.onVisible)
    this.schedule()
  }

  disconnect() {
    clearTimeout(this.timer)
    document.removeEventListener("visibilitychange", this.onVisible)
  }

  schedule() { this.timer = setTimeout(() => this.tick(), this.everyValue) }

  async tick() {
    clearTimeout(this.timer)
    if (document.hidden) return this.state("paused") // resumes on visibilitychange
    try {
      let hit = false
      for (const [chain, since] of Object.entries(this.cursors)) {
        const r = await fetch(`/idx/${chain}/pulse?since=${since}`, { headers: { accept: "application/json" } })
        if (!r.ok) throw new Error(r.status)
        const p = await r.json()
        if (p.cursor > since) this.cursors[chain] = p.cursor
        if (this.hasTokenValue && this.tokenValue && (p.tokens || []).includes(this.tokenValue)) hit = true
        if (p.head - p.cursor < 2000) { // a chain still replaying history only brings old news
          this.newLaunches += p.launches || 0
          if (this.tradesValue) this.newTrades += p.trades || 0
        }
      }
      this.state("live")
      if (hit) await this.refresh()
      if (this.hasBannerTarget) this.showBanner()
    } catch (_) {
      this.state("offline")
    }
    this.schedule()
  }

  state(s) {
    if (!this.hasDotTarget) return
    this.dotTarget.dataset.state = s
    this.dotTarget.textContent = t(`live.${s}`)
  }

  showBanner() {
    if (!this.newLaunches && !this.newTrades) return
    const parts = []
    if (this.newLaunches) parts.push(t(this.newLaunches > 1 ? "live.launches" : "live.launch", { n: this.newLaunches }))
    if (this.newTrades) parts.push(t(this.newTrades > 1 ? "live.trades" : "live.trade", { n: this.newTrades }))
    this.bannerTextTarget.textContent = parts.join(" · ")
    this.bannerTarget.hidden = false
  }

  // swap the [data-live] blocks with the freshly rendered ones (attributes such as hidden stay ours)
  async refresh() {
    const r = await fetch(location.href, { headers: { accept: "text/html" } })
    if (!r.ok) return
    const doc = new DOMParser().parseFromString(await r.text(), "text/html")
    const seen = new Set([...document.querySelectorAll("[data-live='trades'] tr[data-key]")].map((tr) => tr.dataset.key))
    doc.querySelectorAll("[data-live]").forEach((fresh) => {
      const el = document.querySelector(`[data-live="${fresh.dataset.live}"]`)
      if (el && el.innerHTML !== fresh.innerHTML) el.innerHTML = fresh.innerHTML
    })
    document.querySelectorAll("[data-live='trades'] tr[data-key]").forEach((tr) => {
      if (!seen.has(tr.dataset.key)) tr.classList.add("fresh")
    })
  }
}
