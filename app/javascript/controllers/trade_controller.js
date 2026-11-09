import { Controller } from "@hotwired/stimulus"
import { t } from "../par/i18n"
import { formatUnits, parseUnits } from "viem"
import { getLaunch, getEthRoutes, quoteBuyWithEth, quoteSellToEth, buildBuyWithEth, buildSellToEth, buildApprove, withSlippage, erc20Abi } from "par-sdk"
import { publicClient, sendTx, onWallet, walletState, errMsg, compact, short, units, showMsg } from "../par/wallet"

// Buy / sell box on a token page. Quotes by simulating the par router call; trades through the user's wallet.
export default class extends Controller {
  static values = { chain: Object, token: String, symbol: String }
  static targets = ["amount", "out", "submit", "msg", "balance", "payUnit", "presets", "sideButton"]

  async connect() {
    this.ci = this.chainValue
    this.ref = this.ci.reference
    this.pc = publicClient(this.ci)
    this.sideName = "buy"
    this.slip = 300
    this.bal = { ref: 0n, token: 0n }
    this.off = onWallet(() => this.refreshBalances())
    try {
      this.launch = await getLaunch(this.pc, this.tokenValue, this.ci.id)
      this.routes = await getEthRoutes(this.pc, this.launch, this.ci.id)
      if (this.routes.every((r) => r === null)) {
        this.submitTarget.textContent = t("trade.no_route", { ref: this.ref.symbol })
        return
      }
      this.render()
    } catch (e) { showMsg(this.msgTarget, false, t("trade.pool_error", { error: errMsg(e) })) }
  }
  disconnect() { this.off?.() }

  get decIn() { return this.sideName === "buy" ? this.ref.decimals : 18 }
  get decOut() { return this.sideName === "buy" ? 18 : this.ref.decimals }
  get raw() { try { return this.amountTarget.value ? parseUnits(this.amountTarget.value.replace(",", "."), this.decIn) : 0n } catch { return 0n } }

  side(e) {
    this.sideName = e.currentTarget.dataset.side
    this.sideButtonTargets.forEach((b) => { b.classList.toggle("active", b.dataset.side === this.sideName); b.classList.toggle(this.sideName, b.dataset.side === this.sideName) })
    this.amountTarget.value = ""
    this.presetsTarget.innerHTML = this.sideName === "buy"
      ? ["0.001", "0.01", "0.05", "0.1"].map((v) => `<button class="chip" data-action="trade#preset" data-value="${v}">${v}</button>`).join("")
      : [25, 50, 100].map((p) => `<button class="chip" data-action="trade#preset" data-pct="${p}">${p}%</button>`).join("")
    this.render()
  }

  preset(e) {
    const { value, pct } = e.currentTarget.dataset
    this.amountTarget.value = value ?? formatUnits((this.bal.token * BigInt(pct)) / 100n, 18)
    this.quote()
  }

  max() {
    const v = this.sideName === "buy" ? (this.bal.ref * 95n) / 100n : this.bal.token
    this.amountTarget.value = formatUnits(v, this.decIn)
    this.quote()
  }

  slippage(e) {
    this.slip = Number(e.currentTarget.dataset.bps)
    e.currentTarget.parentElement.querySelectorAll(".chip").forEach((c) => c.classList.toggle("on", c === e.currentTarget))
  }

  async refreshBalances() {
    const w = walletState()
    if (!w.address || !this.pc) return
    const [r, t] = await Promise.all([
      this.ref.native ? this.pc.getBalance({ address: w.address }) : this.pc.readContract({ address: this.ref.address, abi: erc20Abi, functionName: "balanceOf", args: [w.address] }),
      this.pc.readContract({ address: this.tokenValue, abi: erc20Abi, functionName: "balanceOf", args: [w.address] }),
    ]).catch(() => [0n, 0n])
    this.bal = { ref: r, token: t }
    this.render()
  }

  render() {
    const buy = this.sideName === "buy"
    this.payUnitTarget.textContent = buy ? this.ref.symbol : this.symbolValue
    this.balanceTarget.textContent = walletState().address ? " " + t("trade.balance", { amount: compact(units(buy ? this.bal.ref : this.bal.token, this.decIn)) }) : ""
    const approving = buy && this.needsApproval
    this.submitTarget.textContent = approving ? t("trade.approve", { symbol: this.ref.symbol }) : t(buy ? "trade.buy" : "trade.sell", { symbol: this.symbolValue })
    this.submitTarget.classList.toggle("primary", buy)
    this.submitTarget.classList.toggle("danger", !buy)
    // never trade without a fresh quote: the quote is what sets the minimum received (slippage protection)
    this.submitTarget.disabled = this.raw === 0n || !this.launch || (!approving && this.quoted == null)
  }

  quote() {
    this.quoted = null
    this.needsApproval = false
    this.render()
    this.outTarget.textContent = "—"
    clearTimeout(this.timer)
    const raw = this.raw
    if (!raw || !this.launch) return
    this.timer = setTimeout(async () => {
      try {
        const owner = walletState().address ?? undefined
        // ERC-20 reference (USDC on Arc): the router pulls the input from an allowance that a simulation cannot fake,
        // so a buy can only be quoted from a wallet that has approved the router — approve first, then quote
        if (this.sideName === "buy" && !this.ref.native) {
          if (!owner) { this.outTarget.textContent = t("trade.connect_to_quote"); return }
          const al = await this.pc.readContract({ address: this.ref.address, abi: erc20Abi, functionName: "allowance", args: [owner, this.launch.router] })
          if (raw !== this.raw) return
          if (al < raw) { this.needsApproval = true; this.outTarget.textContent = t("trade.approve_to_quote", { symbol: this.ref.symbol }); this.render(); return }
        }
        const q = this.sideName === "buy"
          ? await quoteBuyWithEth(this.pc, this.launch, this.routes, raw, undefined, this.ci.id, owner)
          : await quoteSellToEth(this.pc, this.launch, this.routes, raw, owner, undefined, this.ci.id)
        if (raw !== this.raw) return
        this.quoted = q
        this.outTarget.textContent = `${compact(units(q, this.decOut))} ${this.sideName === "buy" ? this.symbolValue : this.ref.symbol}`
        this.render()
      } catch (e) { showMsg(this.msgTarget, false, t("trade.quote_failed", { error: errMsg(e) })); this.render() }
    }, 300)
  }

  async submit() {
    const raw = this.raw
    if (!raw || !this.launch) return
    this.msgTarget.hidden = true
    const btn = this.submitTarget
    btn.disabled = true
    try {
      const { address } = walletState()
      if (!address) throw new Error(t("wallet.connect_first"))
      const router = this.launch.router
      if (this.sideName === "buy" && this.needsApproval) {
        btn.textContent = t("trade.approving_symbol", { symbol: this.ref.symbol })
        await sendTx(this.ci, buildApprove(this.ref.address, router))
        showMsg(this.msgTarget, true, t("trade.approved", { symbol: this.ref.symbol }))
        this.quote()
        return
      }
      if (this.quoted == null) throw new Error(t("trade.no_quote"))
      const min = withSlippage(this.quoted, this.slip)
      let receipt
      if (this.sideName === "buy") {
        if (!this.ref.native) await this.approveIfNeeded(this.ref.address, router, raw, address)
        btn.textContent = t("trade.buying")
        receipt = await sendTx(this.ci, buildBuyWithEth(this.launch, this.routes, raw, min, address, undefined, this.ci.id))
      } else {
        await this.approveIfNeeded(this.tokenValue, router, raw, address)
        btn.textContent = t("trade.selling")
        receipt = await sendTx(this.ci, buildSellToEth(this.launch, this.routes, raw, min, address, undefined, this.ci.id))
      }
      showMsg(this.msgTarget, true, t("trade.done", { tx: short(receipt.transactionHash) }))
      this.amountTarget.value = ""
      this.refreshBalances()
    } catch (e) {
      showMsg(this.msgTarget, false, errMsg(e))
    } finally {
      this.render()
    }
  }

  async approveIfNeeded(asset, spender, amount, owner) {
    const allowance = await this.pc.readContract({ address: asset, abi: erc20Abi, functionName: "allowance", args: [owner, spender] })
    if (allowance >= amount) return
    this.submitTarget.textContent = t("trade.approving")
    await sendTx(this.ci, buildApprove(asset, spender))
  }
}
