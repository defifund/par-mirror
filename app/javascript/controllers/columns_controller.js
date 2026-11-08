import { Controller } from "@hotwired/stimulus"

// Daily column chart (single or stacked) drawn as SVG.
// Specs (dataviz): columns ≤ 24px, 4px rounded data-end, square at the baseline; 2px surface gap
// between touching bars and stacked segments; 1px solid recessive gridlines; one y-axis;
// legend for ≥ 2 series; per-day hover tooltip (values lead, labels follow); table view.
// Colors come from CSS custom properties (--series-N), text from text tokens only.
const NS = "http://www.w3.org/2000/svg"
const H = 200, PAD = { top: 10, right: 8, bottom: 24, left: 48 }

export default class extends Controller {
  static values = { days: Array, series: Array, format: String }
  static targets = ["plot", "legend", "tip", "table"]

  connect() {
    this.ro = new ResizeObserver(() => this.render())
    this.ro.observe(this.plotTarget)
    this.renderLegend()
    this.renderTable()
  }
  disconnect() { this.ro?.disconnect() }

  // values: compact from 10,000 up. Axis ticks pass `compactAxis` so one axis never mixes "5,000" and "10K".
  fmt(v, compactAxis = false) {
    const f = this.formatValue
    const c = (n) => {
      const a = Math.abs(n)
      const short = (x, u) => (n / x).toFixed(1).replace(/\.0$/, "") + u
      if (a >= 1e9) return short(1e9, "B")
      if (a >= 1e6) return short(1e6, "M")
      if (a >= 1e4 || (compactAxis && a >= 1e3)) return short(1e3, "K")
      if (a >= 100 || Number.isInteger(n)) return Math.round(n).toLocaleString()
      return n.toLocaleString(undefined, { maximumSignificantDigits: 3 })
    }
    return f === "usd" ? "$" + c(v) : c(v)
  }
  dayLabel(t, long = false) {
    return new Date(t * 1000).toLocaleDateString(undefined, long ? { year: "numeric", month: "short", day: "numeric", timeZone: "UTC" } : { month: "short", day: "numeric", timeZone: "UTC" })
  }
  total(d) { return this.seriesValue.reduce((a, s) => a + (d[s.key] || 0), 0) }

  // clean ticks: steps of 1/2/2.5/5 × 10^k, about four of them, the top one just covering the max
  ticks(max) {
    if (max <= 0) return [0, 1]
    const raw = max / 4, p = 10 ** Math.floor(Math.log10(raw))
    let step = [1, 2, 2.5, 5, 10].map((m) => m * p).find((s) => s >= raw)
    if (this.formatValue === "count") step = Math.max(1, Math.ceil(step))
    const n = Math.ceil(max / step - 1e-9)
    return Array.from({ length: n + 1 }, (_, i) => i * step)
  }

  el(name, attrs = {}, parent) {
    const e = document.createElementNS(NS, name)
    for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v)
    parent?.appendChild(e)
    return e
  }

  render() {
    const days = this.daysValue, series = this.seriesValue
    const W = this.plotTarget.clientWidth
    if (!W) return
    this.plotTarget.querySelector("svg")?.remove() // keep the tooltip element
    const svg = this.el("svg", { width: W, height: H, role: "img", "aria-label": this.element.dataset.title || "chart" })
    this.plotTarget.prepend(svg)
    const ticks = this.ticks(Math.max(0, ...days.map((d) => this.total(d))))
    const top = ticks[ticks.length - 1]
    const iw = W - PAD.left - PAD.right, ih = H - PAD.top - PAD.bottom
    const y = (v) => PAD.top + ih - (v / top) * ih

    for (const t of ticks) {
      this.el("line", { x1: PAD.left, x2: W - PAD.right, y1: y(t), y2: y(t), class: "grid" }, svg)
      const lab = this.el("text", { x: PAD.left - 8, y: y(t) + 4, "text-anchor": "end", class: "tick" }, svg)
      lab.textContent = this.fmt(t, top >= 1e4)
    }
    if (!days.length) return

    const band = iw / days.length
    const bw = Math.max(1, Math.min(24, band - 2)) // 2px surface gap between neighbours
    const r = Math.min(4, bw / 2)
    days.forEach((d, i) => {
      const x = PAD.left + i * band + (band - bw) / 2
      let base = 0
      const parts = series.map((s, k) => ({ s, k, v: d[s.key] || 0 })).filter((p) => p.v > 0)
      parts.forEach((p, j) => {
        const y0 = y(base), y1 = y(base + p.v)
        const gap = j > 0 ? 2 : 0 // surface gap between stacked segments
        const h = Math.max(0, y0 - y1 - gap)
        if (h <= 0) { base += p.v; return }
        const isTop = j === parts.length - 1
        const yt = y0 - gap - h, rr = isTop ? Math.min(r, h) : 0
        // rounded data-end on the top segment only, square at the baseline
        this.el("path", {
          d: `M${x},${y0 - gap} V${yt + rr} Q${x},${yt} ${x + rr},${yt} H${x + bw - rr} Q${x + bw},${yt} ${x + bw},${yt + rr} V${y0 - gap} Z`,
          class: `bar s${p.k + 1}`, "data-i": i,
        }, svg)
        base += p.v
      })
      // the whole day column is the hit target
      const hit = this.el("rect", { x: PAD.left + i * band, y: PAD.top, width: band, height: ih, class: "hit", tabindex: 0, "data-i": i }, svg)
      hit.addEventListener("pointerenter", () => this.show(i))
      hit.addEventListener("focus", () => this.show(i))
      hit.addEventListener("pointerleave", () => this.hide())
      hit.addEventListener("blur", () => this.hide())
    })
    this.el("line", { x1: PAD.left, x2: W - PAD.right, y1: y(0), y2: y(0), class: "axis" }, svg)
    const picks = days.length > 2 ? [0, Math.floor(days.length / 2), days.length - 1] : days.map((_, i) => i)
    picks.forEach((i, n) => {
      const x = PAD.left + i * band + band / 2
      const t = this.el("text", { x, y: H - 6, "text-anchor": n === 0 ? "start" : n === picks.length - 1 ? "end" : "middle", class: "tick" }, svg)
      t.textContent = this.dayLabel(days[i].day)
    })
    this.svg = svg
  }

  show(i) {
    const d = this.daysValue[i]
    this.svg?.querySelectorAll(".bar").forEach((b) => b.classList.toggle("dim", Number(b.dataset.i) !== i))
    const tip = this.tipTarget
    tip.replaceChildren()
    const head = document.createElement("div")
    head.className = "tip-day"
    head.textContent = this.dayLabel(d.day, true)
    tip.appendChild(head)
    const rows = this.seriesValue.length > 1 ? [...this.seriesValue, { key: null, label: "Total" }] : this.seriesValue
    rows.forEach((s, k) => {
      const row = document.createElement("div")
      row.className = "tip-row"
      const key = document.createElement("span")
      key.className = s.key ? `tip-key s${k + 1}` : "tip-key none"
      const val = document.createElement("b")
      val.textContent = this.fmt(s.key ? d[s.key] || 0 : this.total(d))
      const lab = document.createElement("span")
      lab.className = "muted"
      lab.textContent = s.label
      row.append(key, val, lab)
      tip.appendChild(row)
    })
    tip.hidden = false
    const W = this.plotTarget.clientWidth, band = (W - PAD.left - PAD.right) / this.daysValue.length
    const cx = PAD.left + i * band + band / 2
    const left = Math.min(Math.max(cx - tip.offsetWidth / 2, 0), W - tip.offsetWidth)
    tip.style.left = `${left}px`
    tip.style.top = `${-tip.offsetHeight - 6}px`
  }
  hide() {
    this.tipTarget.hidden = true
    this.svg?.querySelectorAll(".bar.dim").forEach((b) => b.classList.remove("dim"))
  }

  renderLegend() {
    if (!this.hasLegendTarget) return
    this.legendTarget.replaceChildren()
    if (this.seriesValue.length < 2) { this.legendTarget.hidden = true; return }
    this.seriesValue.forEach((s, k) => {
      const item = document.createElement("span")
      item.className = "legend-item"
      const sw = document.createElement("span")
      sw.className = `swatch s${k + 1}`
      const lab = document.createElement("span")
      lab.textContent = s.label
      item.append(sw, lab)
      this.legendTarget.appendChild(item)
    })
  }

  renderTable() {
    if (!this.hasTableTarget) return
    const t = document.createElement("table")
    t.className = "table small"
    const hr = t.createTHead().insertRow()
    for (const h of ["Day", ...this.seriesValue.map((s) => s.label)]) { const th = document.createElement("th"); th.textContent = h; hr.appendChild(th) }
    const body = t.createTBody()
    for (const d of [...this.daysValue].reverse()) {
      const r = body.insertRow()
      r.insertCell().textContent = this.dayLabel(d.day, true)
      for (const s of this.seriesValue) r.insertCell().textContent = this.fmt(d[s.key] || 0)
    }
    this.tableTarget.replaceChildren(t)
  }
}
