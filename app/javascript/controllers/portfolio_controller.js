import { Controller } from "@hotwired/stimulus"
import { encodeFunctionData } from "viem"
import { feeEscrowAbi } from "par-sdk"
import { t } from "../par/i18n"
import { sendTx, walletState, onWallet, errMsg, compact, short, units, showMsg } from "../par/wallet"

// Creator fee balances in the escrow, with claim buttons when the page belongs to the connected wallet.
export default class extends Controller {
  static values = { chain: Object, owner: String }
  static targets = ["claimable"]

  connect() {
    if (!this.ownerValue || !this.hasClaimableTarget) return
    this.off = onWallet(() => this.render())
    this.load()
  }
  disconnect() { this.off?.() }

  async load() {
    try {
      this.claims = await (await fetch(`/idx/${this.chainValue.id}/claimable?owner=${this.ownerValue}`)).json()
      this.render()
    } catch (e) { this.claimableTarget.textContent = errMsg(e) }
  }

  render() {
    const d = this.claims
    if (!d) return
    const mine = walletState().address === this.ownerValue
    const ref = this.chainValue.reference.symbol
    const rows = []
    if (BigInt(d.native) > 0n) rows.push({ label: `${compact(units(d.native))} ${ref}`, asset: null })
    for (const tok of d.tokens) rows.push({ label: `${compact(units(tok.amount, tok.decimals))} ${tok.symbol ?? short(tok.asset)}`, asset: tok.asset })
    if (!rows.length) { this.claimableTarget.innerHTML = `<span class="muted">${t("portfolio.nothing_waiting")}</span>`; return }
    this.claimableTarget.innerHTML = rows.map((r) => `<div class="row gap between claim-row"><b>${r.label}</b>${mine ? `<button class="btn small" data-action="portfolio#claim" data-asset="${r.asset ?? ""}">${t("portfolio.claim")}</button>` : ""}</div>`).join("")
      + (mine ? "" : `<p class="muted small">${t("portfolio.connect_as", { who: short(this.ownerValue) })}</p>`) + `<div class="msg" hidden></div>`
  }

  async claim(e) {
    const btn = e.currentTarget
    const asset = btn.dataset.asset
    const msg = this.claimableTarget.querySelector(".msg")
    btn.disabled = true
    try {
      const data = asset
        ? encodeFunctionData({ abi: feeEscrowAbi, functionName: "claimToken", args: [asset] })
        : encodeFunctionData({ abi: feeEscrowAbi, functionName: "claim", args: [] })
      const r = await sendTx(this.chainValue, { to: this.chainValue.addresses.feeEscrow, data, value: 0n })
      showMsg(msg, true, t("portfolio.claimed", { tx: short(r.transactionHash) }))
      this.load()
    } catch (err) { showMsg(msg, false, errMsg(err)); btn.disabled = false }
  }
}
