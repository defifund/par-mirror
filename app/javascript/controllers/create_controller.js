import { Controller } from "@hotwired/stimulus"
import { encodeFunctionData, parseAbi, parseUnits, zeroAddress, toHex, decodeEventLog } from "viem"
import { factoryAbi, multiFactoryAbi, multiRouterAbi, quotePricerAbi, erc20Abi, getEthRoute, buildLegs } from "par-sdk"

// PairPadRouter.launchAndBuyWithEth (from par-sdk abi/PairPadRouter.json; the SDK's own routerAbi omits it)
const routerAbi = parseAbi([
  "struct Socials { string twitter; string telegram; string discord; string website; string farcaster; }",
  "struct TokenParams { string name; string symbol; string logo; string description; Socials socials; address creatorFeeRecipient; uint16 creatorTaxBps; bytes32 expectedEconomics; bytes32 salt; }",
  "struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }",
  "struct Hop { PoolKey key; bool v3; }",
  "function launchAndBuyWithEth(TokenParams params, uint256 launchConfigId, address pairToken, Hop[] leg, uint256 minTokensOut) payable returns (address token, bytes32 poolId, uint256 tokensOut)",
])
import { publicClient, sendTx, walletState, onWallet, errMsg, compact, short, units, showMsg } from "../par/wallet"

const MAX_MARKETS = 5
// last 8 bytes of every salt from this mirror: ASCII "PARMIRR1" (see app/lib/par/mirror_tag.rb)
const MIRROR_TAG = "5041524d49525231"
const statusAbi = parseAbi([
  "function launchEnabled() view returns (bool)",
  "function canLaunch(address launcher) view returns (bool)",
])

// Launch form: one pair -> PairPadRouter.launchAndBuyWithEth, 2..5 pairs -> PairPadMultiRouter.launchAndBuyWithEth.
export default class extends Controller {
  static values = { chain: Object, modes: Array }
  static targets = ["status", "name", "symbol", "logo", "description", "social", "custom", "pairs", "tax", "taxLabel", "feeLine", "devBuy", "launchFee", "startMcap", "submit", "msg"]

  async connect() {
    this.ci = this.chainValue
    this.a = this.ci.addresses
    this.pc = publicClient(this.ci)
    this.pairs = [{ address: zeroAddress, symbol: this.ci.reference.symbol, decimals: 18 }]
    this.feeMode = "creator"
    this.renderPairs()
    try {
      const read = (fn, args = []) => this.pc.readContract({ address: this.a.factory, abi: factoryAbi, functionName: fn, args })
      const [launchFee, maxTax, baseFee, share, phantom] = await Promise.all([read("launchFee"), read("maxCreatorTaxBps"), read("baseFeeBps"), read("protocolFeeShareBps"), read("previewQuoteEconomics", [0n, zeroAddress])])
      const multiLaunchFee = await this.pc.readContract({ address: this.a.multiFactory, abi: multiFactoryAbi, functionName: "launchFee" })
      this.econ = { launchFee, multiLaunchFee, maxTax: Number(maxTax), baseFee: Number(baseFee), share: Number(share) }
      this.taxTarget.max = String(this.econ.maxTax)
      this.launchFeeTarget.textContent = compact(units(launchFee))
      this.startMcapTarget.textContent = `a phantom reserve of ${compact(units(phantom))} ${this.ci.reference.symbol}`
      this.tax()
    } catch (e) { showMsg(this.msgTarget, false, "Could not read factory terms: " + errMsg(e)) }
    this.offWallet = onWallet(() => this.checkStatus())
  }
  disconnect() { this.offWallet?.() }

  // The factory owner (the original team) can close launching at any time; say so instead of
  // letting the wallet fail on a reverted transaction.
  async checkStatus() {
    try {
      const read = (address, functionName, args = []) => this.pc.readContract({ address, abi: statusAbi, functionName, args })
      const [single, multi] = await Promise.all([read(this.a.factory, "launchEnabled"), read(this.a.multiFactory, "launchEnabled")])
      const { address } = walletState()
      const [mayS, mayM] = address ? await Promise.all([read(this.a.factory, "canLaunch", [address]), read(this.a.multiFactory, "canLaunch", [address])]) : [true, true]
      this.open = { single: single && mayS, multi: multi && mayM }
      this.closedReason = !single && !multi ? "Launching has been closed on both par factories by their owner (the original team). Existing tokens keep trading; new launches need a factory this mirror deploys itself."
        : (single && multi) ? (mayS && mayM ? null : "The factories are restricted to whitelisted wallets right now, and this wallet is not on the list.")
        : `Launching is closed on the ${single ? "multi" : "single"}-market factory; ${single ? "use one pair" : "use two or more pairs"}.`
      this.renderStatus()
    } catch (e) { /* status is advisory; the launch call itself is still simulated before sending */ }
  }

  renderStatus() {
    if (!this.open) return
    const ok = this.multi ? this.open.multi : this.open.single
    this.statusTarget.hidden = !this.closedReason
    this.statusTarget.textContent = this.closedReason ?? ""
    this.submitTarget.disabled = !ok
  }

  get multi() { return this.pairs.length > 1 }

  get launchFee() { return this.multi ? this.econ?.multiLaunchFee : this.econ?.launchFee }

  renderPairs() {
    this.renderStatus?.()
    if (this.econ && this.hasLaunchFeeTarget) this.launchFeeTarget.textContent = compact(units(this.launchFee))
    this.pairsTarget.innerHTML = this.pairs.map((p, i) =>
      `<span class="tag">${p.symbol}${this.pairs.length > 1 ? ` <a href="#" data-action="create#removePair" data-index="${i}">×</a>` : ""}</span>`).join(" ")
    this.element.querySelectorAll("[data-action='create#togglePreset']").forEach((b) => b.classList.toggle("on", this.pairs.some((p) => p.address === b.dataset.address.toLowerCase())))
  }

  removePair(e) {
    e.preventDefault()
    this.pairs.splice(Number(e.currentTarget.dataset.index), 1)
    this.renderPairs()
  }

  async togglePreset(e) {
    const addr = e.currentTarget.dataset.address.toLowerCase()
    const i = this.pairs.findIndex((p) => p.address === addr)
    if (i >= 0) { if (this.pairs.length > 1) this.pairs.splice(i, 1); this.renderPairs(); return }
    await this.addPair(addr, { symbol: e.currentTarget.dataset.symbol, decimals: Number(e.currentTarget.dataset.decimals) })
  }

  addCustom() { this.addPair(this.customTarget.value.trim().toLowerCase()) }

  async addPair(addr, known) {
    this.msgTarget.hidden = true
    try {
      if (!/^0x[0-9a-f]{40}$/.test(addr)) throw new Error("Not an address")
      if (this.pairs.some((p) => p.address === addr)) return
      if (this.pairs.length >= MAX_MARKETS) throw new Error(`At most ${MAX_MARKETS} markets`)
      if (addr !== zeroAddress) {
        const ok = await this.pc.readContract({ address: this.a.quotePricer, abi: quotePricerAbi, functionName: "isPriceable", args: [addr] })
        if (!ok) throw new Error("The on-chain pricer cannot price this asset (it needs a deep enough Uniswap route to ETH)")
      }
      const meta = known ?? {
        symbol: await this.pc.readContract({ address: addr, abi: erc20Abi, functionName: "symbol" }),
        decimals: Number(await this.pc.readContract({ address: addr, abi: erc20Abi, functionName: "decimals" })),
      }
      this.pairs.push({ address: addr, ...meta })
      this.customTarget.value = ""
      this.renderPairs()
    } catch (e) { showMsg(this.msgTarget, false, errMsg(e)) }
  }

  mode(e) {
    this.feeMode = e.currentTarget.value
    this.element.querySelectorAll(".opt").forEach((o) => o.classList.toggle("on", o.contains(e.currentTarget)))
  }

  tax() {
    const bps = Number(this.taxTarget.value)
    this.taxLabelTarget.textContent = `${(bps / 100).toFixed(1)}%`
    const base = this.econ?.baseFee ?? 100, share = this.econ?.share ?? 5000
    this.feeLineTarget.textContent = `Every trade pays a ${((base + bps) / 100).toFixed(2)}% pool fee: ${base / 100}% base fee (${share / 100}% of it to the protocol) plus your ${(bps / 100).toFixed(1)}% tax.`
  }

  async upload(e) {
    const file = e.target.files?.[0]
    if (!file) return
    showMsg(this.msgTarget, true, "Uploading image…")
    try {
      const fd = new FormData()
      fd.append("file", file)
      const r = await fetch("/api/upload", { method: "POST", body: fd })
      const j = await r.json()
      if (!r.ok) throw new Error(j.error)
      this.logoTarget.value = j.uri
      showMsg(this.msgTarget, true, `Pinned as ${j.uri}`)
    } catch (err) { showMsg(this.msgTarget, false, errMsg(err)) }
  }

  async launch() {
    this.msgTarget.hidden = true
    const btn = this.submitTarget
    try {
      const { address } = walletState()
      if (!address) throw new Error("Connect a wallet first")
      if (!this.econ) throw new Error("Factory terms are not loaded yet")
      if (!this.ci.reference.native) throw new Error("Launching from this mirror needs a chain whose reference asset is native (Robinhood Chain)")
      const name = this.nameTarget.value.trim(), symbol = this.symbolTarget.value.trim().toUpperCase()
      if (!name || !symbol) throw new Error("Name and ticker are required")
      if (!this.modesValue.includes(this.feeMode)) throw new Error(`The "${this.feeMode}" fee mode is not available on this mirror`)
      const recipient = { creator: address, holders: this.a.holderVault, burn: this.a.burnVault, floor: this.a.floorVault }[this.feeMode]
      if (!recipient || recipient === zeroAddress) throw new Error("This fee mode is not deployed on this chain")
      const socials = Object.fromEntries(this.socialTargets.map((el) => [el.dataset.key, el.value.trim()]))
      for (const [k, v] of Object.entries(socials)) if (v && !/^https?:\/\//.test(v)) throw new Error(`${k} must be a full https:// URL`)
      const params = {
        name, symbol, logo: this.logoTarget.value.trim(), description: this.descriptionTarget.value.trim(),
        socials: { twitter: socials.twitter, telegram: socials.telegram, discord: socials.discord, website: socials.website, farcaster: socials.farcaster },
        creatorFeeRecipient: recipient, creatorTaxBps: Number(this.taxTarget.value),
        expectedEconomics: "0x" + "0".repeat(64), // unpinned: quotes priced off live pools move every block
        salt: toHex(crypto.getRandomValues(new Uint8Array(24))) + MIRROR_TAG, // 24 random bytes + tag
      }
      const buy = this.devBuyTarget.value ? parseUnits(this.devBuyTarget.value.replace(",", "."), 18) : 0n
      let tx
      if (!this.multi) {
        const p = this.pairs[0]
        const route = await getEthRoute(this.pc, p.address, this.ci.id)
        if (buy > 0n && !route) throw new Error(`No ${this.ci.reference.symbol} route to ${p.symbol}; set the opening buy to 0`)
        tx = { to: this.a.router, value: this.launchFee + buy,
               data: encodeFunctionData({ abi: routerAbi, functionName: "launchAndBuyWithEth", args: [params, 0n, p.address, route?.buyHops ?? [], 0n] }) }
      } else {
        const routes = await Promise.all(this.pairs.map((p) => getEthRoute(this.pc, p.address, this.ci.id)))
        const legs = buy > 0n ? buildLegs({ markets: this.pairs.map((_, i) => ({ index: i })) }, routes, buy, "buy") : []
        tx = { to: this.a.multiRouter, value: this.launchFee + buy,
               data: encodeFunctionData({ abi: multiRouterAbi, functionName: "launchAndBuyWithEth", args: [params, 0n, this.pairs.map((p) => p.address), legs, 0n] }) }
      }
      btn.disabled = true
      btn.textContent = "Confirm in your wallet…"
      const receipt = await sendTx(this.ci, tx)
      let token = null
      for (const l of receipt.logs) {
        try {
          const ev = decodeEventLog({ abi: this.multi ? multiFactoryAbi : factoryAbi, data: l.data, topics: l.topics })
          if (ev.eventName === "TokenLaunched") { token = ev.args.token.toLowerCase(); break }
        } catch {}
      }
      showMsg(this.msgTarget, true, `Launched ${token ? short(token) : ""} in ${short(receipt.transactionHash)}. Its page appears as soon as the indexer reaches the block.`)
      if (token) setTimeout(() => window.Turbo.visit(`/token/${this.ci.slug}/${token}`), 5000)
    } catch (e) { showMsg(this.msgTarget, false, errMsg(e)) }
    finally { btn.disabled = false; btn.textContent = "Launch" }
  }
}
