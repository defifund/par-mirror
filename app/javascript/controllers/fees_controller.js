import { Controller } from "@hotwired/stimulus"
import { encodeFunctionData } from "viem"
import { lockerAbi, multiLockerAbi } from "par-sdk"
import { sendTx, errMsg, compact, short, units, showMsg } from "../par/wallet"

// Uncollected fees (live from the locker via the API) and the permissionless collectFees call.
export default class extends Controller {
  static values = { chain: Object, token: String, kind: String, url: String, markets: Array, symbol: String }
  static targets = ["pending", "button", "msg"]

  connect() { this.load() }

  async load() {
    try {
      const d = await (await fetch(this.urlValue)).json()
      if (!Array.isArray(d.pending)) { this.pendingTarget.textContent = "—"; return }
      this.pendingTarget.innerHTML = d.pending.map((p) => {
        const m = this.marketsValue[p.market] ?? this.marketsValue[0]
        const tokIs0 = BigInt(this.tokenValue) < BigInt(m.pairToken)
        const [q, t] = tokIs0 ? [p.amount1, p.amount0] : [p.amount0, p.amount1]
        const label = this.marketsValue.length > 1 ? `market ${p.market}: ` : ""
        return `<div>${label}${compact(units(q, m.quoteDecimals))} ${m.quoteSymbol} + ${compact(units(t))} ${this.symbolValue}</div>`
      }).join("")
    } catch { this.pendingTarget.textContent = "—" }
  }

  async collect() {
    this.buttonTarget.disabled = true
    this.buttonTarget.textContent = "Collecting…"
    try {
      const single = this.kindValue === "single"
      const a = this.chainValue.addresses
      const data = encodeFunctionData({ abi: single ? lockerAbi : multiLockerAbi, functionName: "collectFees", args: [this.tokenValue] })
      const r = await sendTx(this.chainValue, { to: single ? a.locker : a.multiLocker, data, value: 0n })
      showMsg(this.msgTarget, true, `Collected in ${short(r.transactionHash)}. The creator share is now claimable from the escrow.`)
      this.load()
    } catch (e) { showMsg(this.msgTarget, false, errMsg(e)) }
    finally { this.buttonTarget.disabled = false; this.buttonTarget.textContent = "Collect fees (anyone can)" }
  }
}
