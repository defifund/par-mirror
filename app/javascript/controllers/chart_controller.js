import { Controller } from "@hotwired/stimulus"
import { createChart } from "lightweight-charts"
import { price } from "../par/wallet"

// Candles from /idx/<chain>/candles, in USD (via the reference/USD rate) or the reference asset.
export default class extends Controller {
  static values = { url: String, usd: Number, ref: String }
  static targets = ["canvas", "intervals", "units", "empty"]

  connect() {
    this.iv = "15m"
    this.unitName = this.usdValue > 0 ? "usd" : "ref"
    const dark = matchMedia("(prefers-color-scheme: dark)").matches
    this.chart = createChart(this.canvasTarget, {
      height: 360, autoSize: true,
      layout: { background: { color: "transparent" }, textColor: dark ? "#cbbfae" : "#5b4a3d" },
      grid: { vertLines: { color: dark ? "#2a221c" : "#efe5cc" }, horzLines: { color: dark ? "#2a221c" : "#efe5cc" } },
      timeScale: { timeVisible: true, secondsVisible: false },
      rightPriceScale: { borderVisible: false },
    })
    this.series = this.chart.addCandlestickSeries({
      upColor: "#2e9e6a", downColor: "#d4574b", borderVisible: false, wickUpColor: "#2e9e6a", wickDownColor: "#d4574b",
      priceFormat: { type: "custom", formatter: (p) => price(p), minMove: 1e-12 },
    })
    this.load()
    this.poll = setInterval(() => this.load(), 15000)
  }
  disconnect() { clearInterval(this.poll); this.chart?.remove() }

  interval(e) { this.iv = e.currentTarget.dataset.interval; this.mark(this.intervalsTarget, e.currentTarget); this.load(true) }
  unit(e) { this.unitName = e.currentTarget.dataset.unit; this.mark(this.unitsTarget, e.currentTarget); this.draw(true) }
  mark(group, btn) { group.querySelectorAll("button").forEach((b) => b.classList.toggle("active", b === btn)) }

  async load(fit = false) {
    const r = await fetch(`${this.urlValue}&interval=${this.iv}&limit=500`).then((x) => x.json()).catch(() => null)
    if (!r) return
    this.candles = r.candles
    this.draw(fit || !this.drawn)
  }

  draw(fit) {
    const k = this.unitName === "usd" ? this.usdValue : 1
    this.series.setData((this.candles ?? []).map((c) => ({ time: c.time, open: c.openEth * k, high: c.highEth * k, low: c.lowEth * k, close: c.closeEth * k })))
    this.emptyTarget.hidden = (this.candles ?? []).length > 0
    if (fit) this.chart.timeScale().fitContent()
    this.drawn = true
  }
}
