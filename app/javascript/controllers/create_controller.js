import { Controller } from "@hotwired/stimulus"
import { encodeFunctionData, parseAbi, parseUnits, zeroAddress, toHex, decodeEventLog } from "viem"
import { factoryAbi, multiFactoryAbi, multiRouterAbi, quotePricerAbi, erc20Abi, getEthRoute, buildLegs, buildApprove } from "par-sdk"

// PairPadRouter.launchAndBuyWithEth (from par-sdk abi/PairPadRouter.json; the SDK's own routerAbi omits it)
const routerAbi = parseAbi([
  "struct Socials { string twitter; string telegram; string discord; string website; string farcaster; }",
  "struct TokenParams { string name; string symbol; string logo; string description; Socials socials; address creatorFeeRecipient; uint16 creatorTaxBps; bytes32 expectedEconomics; bytes32 salt; }",
  "struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }",
  "struct Hop { PoolKey key; bool v3; }",
  "function launchAndBuyWithEth(TokenParams params, uint256 launchConfigId, address pairToken, Hop[] leg, uint256 minTokensOut) payable returns (address token, bytes32 poolId, uint256 tokensOut)",
])
import { t } from "../par/i18n"
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
  static targets = ["pairsNote", "pairSection", "status", "name", "symbol", "logo", "description", "social", "custom", "pairs", "tax", "taxLabel", "feeLine", "devBuy", "launchFee", "startMcap", "submit", "msg",
                    "drop", "preview", "file", "stocksChip", "stocksPanel", "stocksFilter", "stocksList", "stocksNote", "results"]

  async connect() {
    this.ci = this.chainValue
    this.a = this.ci.addresses
    this.pc = publicClient(this.ci)
    this.pairs = [{ address: this.ci.reference.address.toLowerCase(), symbol: this.ci.reference.symbol, decimals: this.ci.reference.decimals }]
    this.feeMode = "creator"
    this.renderPairs()
    try {
      const read = (fn, args = []) => this.pc.readContract({ address: this.a.factory, abi: factoryAbi, functionName: fn, args })
      const [launchFee, maxTax, baseFee, share, phantom] = await Promise.all([read("launchFee"), read("maxCreatorTaxBps"), read("baseFeeBps"), read("protocolFeeShareBps"), read("previewQuoteEconomics", [0n, zeroAddress])])
      const multiLaunchFee = await this.pc.readContract({ address: this.a.multiFactory, abi: multiFactoryAbi, functionName: "launchFee" })
      this.econ = { launchFee, multiLaunchFee, maxTax: Number(maxTax), baseFee: Number(baseFee), share: Number(share) }
      this.taxTarget.max = String(this.econ.maxTax)
      this.launchFeeTarget.textContent = compact(units(launchFee))
      this.startMcapTarget.textContent = t("create.phantom", { amount: compact(units(phantom)), ref: this.ci.reference.symbol })
      this.tax()
    } catch (e) { showMsg(this.msgTarget, false, t("create.terms_error", { error: errMsg(e) })) }
    this.offWallet = onWallet(() => this.checkStatus())
    // paste an image anywhere on the page (not into a text field) to use it as the token image
    this.onPaste = (e) => {
      const file = [...(e.clipboardData?.files || [])].find((f) => f.type.startsWith("image/"))
      if (file) { e.preventDefault(); this.useImage(file) }
    }
    document.addEventListener("paste", this.onPaste)
    this.onDocClick = (e) => { if (this.hasResultsTarget && !e.target.closest(".search-box")) this.resultsTarget.hidden = true }
    document.addEventListener("click", this.onDocClick)
  }
  disconnect() {
    this.offWallet?.()
    document.removeEventListener("paste", this.onPaste)
    document.removeEventListener("click", this.onDocClick)
  }

  // The factory owner (the original team) can close launching at any time; say so instead of
  // letting the wallet fail on a reverted transaction.
  async checkStatus() {
    try {
      const read = (address, functionName, args = []) => this.pc.readContract({ address, abi: statusAbi, functionName, args })
      const [single, multi] = await Promise.all([read(this.a.factory, "launchEnabled"), read(this.a.multiFactory, "launchEnabled")])
      const { address } = walletState()
      const [mayS, mayM] = address ? await Promise.all([read(this.a.factory, "canLaunch", [address]), read(this.a.multiFactory, "canLaunch", [address])]) : [true, true]
      this.open = { single: single && mayS, multi: multi && mayM }
      this.closedReason = !single && !multi ? t("create.closed_both")
        : (single && multi) ? (mayS && mayM ? null : t("create.whitelist"))
        : t(single ? "create.closed_multi" : "create.closed_single")
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

  // chains whose reference asset is an ERC-20 (Arc's USDC) launch through the multi-market router only
  get native() { return this.ci.reference.native }
  get multi() { return this.pairs.length > 1 || !this.native }

  get launchFee() { return this.multi ? this.econ?.multiLaunchFee : this.econ?.launchFee }

  renderPairs() {
    this.renderStatus?.()
    if (this.econ && this.hasLaunchFeeTarget) this.launchFeeTarget.textContent = compact(units(this.launchFee))
    this.pairsTarget.innerHTML = this.pairs.map((p, i) =>
      `<span class="tag">${p.symbol}${this.pairs.length > 1 ? ` <a href="#" data-action="create#removePair" data-index="${i}">×</a>` : ""}</span>`).join(" ")
    this.element.querySelectorAll("[data-action='create#togglePreset']").forEach((b) => b.classList.toggle("on", this.pairs.some((p) => p.address === b.dataset.address.toLowerCase())))
    // say how many markets are left, right where the user is picking (not in the form's message box far below)
    const n = this.pairs.length, full = n >= MAX_MARKETS
    if (this.hasPairSectionTarget) this.pairSectionTarget.classList.toggle("pairs-full", full)
    if (this.hasPairsNoteTarget) {
      this.pairsNoteTarget.textContent = full ? t("create.full", { max: MAX_MARKETS })
        : n > 1 ? t("create.count", { n, max: MAX_MARKETS }) : ""
      this.pairsNoteTarget.classList.toggle("full", full)
    }
    if (this.stocks) this.renderStocks()
  }

  // a click on a sixth pair: make the limit visible instead of doing nothing
  flashFull() {
    if (!this.hasPairsNoteTarget) return showMsg(this.msgTarget, false, t("create.at_most", { max: MAX_MARKETS }))
    const el = this.pairsNoteTarget
    el.classList.remove("flash"); void el.offsetWidth; el.classList.add("flash")
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

  addCustom(e) {
    e?.preventDefault()
    const v = this.customTarget.value.trim().toLowerCase()
    if (/^0x[0-9a-f]{40}$/.test(v)) { this.resultsTarget.hidden = true; return this.addPair(v) }
    if (this.results?.length) return this.pickResult({ preventDefault() {}, currentTarget: { dataset: { index: 0 } } })
  }

  async addPair(addr, known) {
    this.msgTarget.hidden = true
    try {
      if (!/^0x[0-9a-f]{40}$/.test(addr)) throw new Error(t("create.not_address"))
      if (this.pairs.some((p) => p.address === addr)) return
      if (this.pairs.length >= MAX_MARKETS) return this.flashFull()
      if (addr !== zeroAddress && addr !== this.ci.reference.address.toLowerCase()) {
        const ok = await this.pc.readContract({ address: this.a.quotePricer, abi: quotePricerAbi, functionName: "isPriceable", args: [addr] })
        if (!ok) throw new Error(t("create.not_priceable"))
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
    this.feeLineTarget.textContent = t("create.fee_line", { total: ((base + bps) / 100).toFixed(2), base: base / 100, share: share / 100, tax: (bps / 100).toFixed(1) })
  }

  // ---- token image: drop, browse or paste; preview at once, pin to IPFS when this mirror has an upload key ----
  browse(e) { if (e.target !== this.fileTarget) this.fileTarget.click() }
  dragOver(e) { e.preventDefault(); this.dropTarget.classList.add("over") }
  dragLeave() { this.dropTarget.classList.remove("over") }
  drop(e) {
    e.preventDefault()
    this.dropTarget.classList.remove("over")
    const file = [...(e.dataTransfer?.files || [])].find((f) => f.type.startsWith("image/"))
    if (file) this.useImage(file)
  }
  picked(e) { const f = e.target.files?.[0]; if (f) this.useImage(f); e.target.value = "" }

  logoChanged() {
    const v = this.logoTarget.value.trim()
    const url = v.startsWith("ipfs://") ? `/ipfs/${v.slice(7)}` : /^https:\/\//.test(v) ? v : null
    if (url) { this.previewTarget.src = url; this.previewTarget.hidden = false }
  }

  async useImage(file) {
    if (!/^image\/(png|jpeg|gif|webp)$/.test(file.type)) return showMsg(this.msgTarget, false, t("create.image_type"))
    if (file.size > 4 * 1024 * 1024) return showMsg(this.msgTarget, false, t("create.image_size"))
    if (this.previewUrl) URL.revokeObjectURL(this.previewUrl)
    this.previewUrl = URL.createObjectURL(file)
    this.previewTarget.src = this.previewUrl
    this.previewTarget.hidden = false
    if (this.dropTarget.dataset.upload !== "1") {
      return showMsg(this.msgTarget, false, t("create.no_upload"))
    }
    showMsg(this.msgTarget, true, t("create.uploading"))
    try {
      const fd = new FormData()
      fd.append("file", file)
      const r = await fetch("/api/upload", { method: "POST", body: fd })
      const j = await r.json()
      if (!r.ok) throw new Error(j.error)
      this.logoTarget.value = j.uri
      showMsg(this.msgTarget, true, t("create.pinned", { uri: j.uri }))
    } catch (err) { showMsg(this.msgTarget, false, errMsg(err)) }
  }

  // ---- "Stocks" quick pick ----
  async toggleStocks() {
    const open = this.stocksPanelTarget.hidden
    this.stocksPanelTarget.hidden = !open
    this.stocksChipTarget.classList.toggle("on", open)
    if (open && !this.stocks) {
      try {
        const r = await fetch(`/api/stocks?chain=${this.ci.slug}`)
        const j = await r.json()
        if (!r.ok) throw new Error(j.error || "stock list unavailable")
        this.stocks = j
        const by = j.kind === "bridged" ? t("create.bridged_by", { issuer: j.issuer }) : t("create.from", { issuers: j.issuers.map((i) => i.name).join(" & ") })
        const tradable = j.items.filter((i) => i.priceable).length
        this.stocksNoteTarget.innerHTML = t("create.stocks_note", { n: j.items.length, by, tradable, source: `<a href="${j.attribution.url}" target="_blank" rel="noopener">${j.attribution.name}</a>${j.attribution.license ? ` (${j.attribution.license})` : ""}` })
      } catch (e) { this.stocksListTarget.innerHTML = `<span class="muted small">${errMsg(e)}</span>`; return }
    }
    this.renderStocks()
  }

  renderStocks() {
    if (!this.stocks) return
    const q = this.stocksFilterTarget.value.trim().toLowerCase()
    const items = this.stocks.items.filter((i) => !q || i.symbol.toLowerCase().includes(q) || (i.name || "").toLowerCase().includes(q))
    const chosen = new Set(this.pairs.map((p) => p.address))
    this.stocksListTarget.innerHTML = items.slice(0, 120).map((i) =>
      `<button class="chip stock${chosen.has(i.address) ? " on" : ""}" ${i.priceable ? "" : "disabled"} title="${esc(i.name || "")}${i.priceable ? "" : " · " + t("create.not_priced_yet")}"
        data-action="create#pickStock" data-address="${i.address}" data-symbol="${esc(i.symbol)}" data-decimals="${i.decimals}">${esc(i.symbol)}</button>`).join("")
      || `<span class="muted small">${t("create.no_stock_match")}</span>`
  }

  async pickStock(e) {
    const b = e.currentTarget
    const i = this.pairs.findIndex((p) => p.address === b.dataset.address)
    if (i >= 0) { if (this.pairs.length > 1) this.pairs.splice(i, 1); this.renderPairs() }
    else await this.addPair(b.dataset.address, { symbol: b.dataset.symbol, decimals: Number(b.dataset.decimals) })
    this.renderStocks()
  }

  // ---- "Any token": search by name / ticker, or a pasted address ----
  search() {
    clearTimeout(this.searchTimer)
    const q = this.customTarget.value.trim()
    if (q.length < 2) { this.resultsTarget.hidden = true; return }
    this.searchTimer = setTimeout(async () => {
      try {
        const j = await (await fetch(`/api/tokens?chain=${this.ci.slug}&q=${encodeURIComponent(q)}`)).json()
        this.results = j.items
        const label = (k) => (["quote", "verified", "stock", "par"].includes(k) ? t(`create.kind.${k}`) : "")
        this.resultsTarget.innerHTML = j.items.map((it, n) =>
          `<button class="result" data-action="create#pickResult" data-index="${n}"><b>${esc(it.symbol || short(it.address))}</b>
            <span class="muted small">${esc(it.name && it.name !== it.symbol ? it.name : "")} ${label(it.kind) ? `· ${label(it.kind)}` : ""} · ${short(it.address)}</span></button>`).join("")
          || `<div class="muted small pad">${t("create.no_match")}</div>`
        this.resultsTarget.hidden = false
      } catch { this.resultsTarget.hidden = true }
    }, 200)
  }

  async pickResult(e) {
    e.preventDefault()
    const it = this.results[Number(e.currentTarget.dataset.index)]
    this.resultsTarget.hidden = true
    await this.addPair(it.address, it.symbol && it.decimals != null ? { symbol: it.symbol, decimals: Number(it.decimals) } : undefined)
  }

  async launch() {
    this.msgTarget.hidden = true
    const btn = this.submitTarget
    try {
      const { address } = walletState()
      if (!address) throw new Error(t("wallet.connect_first"))
      if (!this.econ) throw new Error(t("create.terms_loading"))
      const name = this.nameTarget.value.trim(), symbol = this.symbolTarget.value.trim().toUpperCase()
      if (!name || !symbol) throw new Error(t("create.name_required"))
      if (!this.modesValue.includes(this.feeMode)) throw new Error(t("create.mode_unavailable", { mode: this.feeMode }))
      const recipient = { creator: address, holders: this.a.holderVault, burn: this.a.burnVault, floor: this.a.floorVault }[this.feeMode]
      if (!recipient || recipient === zeroAddress) throw new Error(t("create.mode_not_deployed"))
      const socials = Object.fromEntries(this.socialTargets.map((el) => [el.dataset.key, el.value.trim()]))
      for (const [k, v] of Object.entries(socials)) if (v && !/^https?:\/\//.test(v)) throw new Error(t("create.url_required", { field: k }))
      const params = {
        name, symbol, logo: this.logoTarget.value.trim(), description: this.descriptionTarget.value.trim(),
        socials: { twitter: socials.twitter, telegram: socials.telegram, discord: socials.discord, website: socials.website, farcaster: socials.farcaster },
        creatorFeeRecipient: recipient, creatorTaxBps: Number(this.taxTarget.value),
        expectedEconomics: "0x" + "0".repeat(64), // unpinned: quotes priced off live pools move every block
        salt: toHex(crypto.getRandomValues(new Uint8Array(24))) + MIRROR_TAG, // 24 random bytes + tag
      }
      const buy = this.devBuyTarget.value ? parseUnits(this.devBuyTarget.value.replace(",", "."), this.ci.reference.decimals) : 0n
      let tx
      if (!this.multi) {
        const p = this.pairs[0]
        const route = await getEthRoute(this.pc, p.address, this.ci.id)
        if (buy > 0n && !route) throw new Error(t("create.no_route", { ref: this.ci.reference.symbol, symbol: p.symbol }))
        tx = { to: this.a.router, value: this.launchFee + buy,
               data: encodeFunctionData({ abi: routerAbi, functionName: "launchAndBuyWithEth", args: [params, 0n, p.address, route?.buyHops ?? [], 0n] }) }
      } else {
        const routes = await Promise.all(this.pairs.map((p) => getEthRoute(this.pc, p.address, this.ci.id)))
        const legs = buy > 0n ? buildLegs({ markets: this.pairs.map((_, i) => ({ index: i })) }, routes, buy, "buy") : []
        const pairTokens = this.pairs.map((p) => p.address)
        if (this.native) {
          tx = { to: this.a.multiRouter, value: this.launchFee + buy,
                 data: encodeFunctionData({ abi: multiRouterAbi, functionName: "launchAndBuyWithEth", args: [params, 0n, pairTokens, legs, 0n] }) }
        } else {
          // ERC-20 reference (USDC on Arc): the opening buy is pulled from an allowance; the launch fee is still `value`
          if (buy > 0n) {
            const allowance = await this.pc.readContract({ address: this.ci.reference.address, abi: erc20Abi, functionName: "allowance", args: [address, this.a.multiRouter] })
            if (allowance < buy) { btn.textContent = t("trade.approving_symbol", { symbol: this.ci.reference.symbol }); await sendTx(this.ci, buildApprove(this.ci.reference.address, this.a.multiRouter)) }
          }
          tx = { to: this.a.multiRouter, value: this.launchFee,
                 data: encodeFunctionData({ abi: multiRouterAbi, functionName: "launchAndBuyWithReference", args: [params, 0n, pairTokens, legs, buy, 0n] }) }
        }
      }
      btn.disabled = true
      btn.textContent = t("create.confirm_wallet")
      const receipt = await sendTx(this.ci, tx)
      let token = null
      for (const l of receipt.logs) {
        try {
          const ev = decodeEventLog({ abi: this.multi ? multiFactoryAbi : factoryAbi, data: l.data, topics: l.topics })
          if (ev.eventName === "TokenLaunched") { token = ev.args.token.toLowerCase(); break }
        } catch {}
      }
      showMsg(this.msgTarget, true, t("create.launched", { token: token ? short(token) : "", tx: short(receipt.transactionHash) }))
      if (token) setTimeout(() => window.Turbo.visit(`/token/${this.ci.slug}/${token}`), 5000)
    } catch (e) { showMsg(this.msgTarget, false, errMsg(e)) }
    finally { btn.disabled = false; btn.textContent = t("create.launch") }
  }
}

function esc(s) { return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]) }
