# Roadmap: full feature parity with the original par.family

Goal (user, 2026-11-08): restore every feature the original site had, across all four chains.
Status legend: [x] done · [~] in progress · [ ] to do · [!] blocked on the user

## Next up (as of 2026-11-09)
1. [x] End-to-end test (2026-11-09, see §5): RH 12/12 and Base 12/12 on anvil forks; Arc via eth_call on the real RPC
2. [ ] Verified quote lists per chain (§1)
3. [ ] Dark-mode visual check (§5)
4. [!] Decide: keeper wallet for `collectFees` / floor `rebalance` (§3) — who funds gas, where the key lives
5. [!] Decide: BNB Chain — first count the par launches there (archive says 29), then degraded mode or skip (§1)

## Known gaps / follow-ups
- [x] **Arc USD prices were 10^12 too small** (fixed 2026-11-09): quotes were priced with 1e18 units of the reference, i.e. 10^12 USDC on Arc; now one whole unit of the chain's reference. Also `price_x18` keeps 18 fractional digits (cheap tokens in a 6-decimal stable had 1–2 significant digits, on RH and Base too). Migration 20261110030000 rescales stored Arc quotes/trades and refills truncated prices from execution prices; `long` market cap $4.92e-09 → ~$4.9K, volume 161K → 301K USD (non-USDC markets were counted as ~0)
- [~] Arc history backfill: server cursor 24,341,806 of head 30,289,019 (2026-11-09); RH and Base are caught up
- [ ] RH stock quick-pick is only as fresh as stocksonchain.io (data stops 2026-10-17): find a fresher list or read Robinhood's beacon directly
- [~] Logo copies: 2,950 of 2,951 CIDs pinned on our node; 1 not found anywhere yet (`PinLogosJob` retries up to 6×)
- [x] First R2 backup: all 2,950 CARs uploaded (2026-11-09); the hourly job keeps new pins backed up
- [ ] Profiles: smart-contract wallets (Safe etc., ERC-1271) can't sign in yet — needs an on-chain `isValidSignature` call
- [ ] `/events` SSE is capped at 1 stream per web process; if SDK users need more, move it off Puma (e.g. a separate small process)

## 1. Multi-chain (original: one app for Robinhood Chain, Arc, Base, BNB Chain)
- [x] Index Base (8453): public RPC base-rpc.publicnode.com, ≤10 addresses per getLogs → `max_addresses: 10` (caught up on the server 2026-11-09)
- [~] Index Arc (5042): public RPC rpc.mainnet.arc.io, log span 2k (20k-result cap), ≤20 addresses per getLogs; reference asset is USDC (ERC-20, 6 decimals, USD = 1) — following the head, history still backfilling
- [!] Index BNB Chain (56) — user decision after counting launches: no keyed RPC (user has none) → degraded mode: seed the 29 archived launches, follow from the head via publicnode (≤10 addresses); history later via a free Etherscan V2 key if the user gets one
- [x] Chain switcher in the header; chain tabs on Explore (All / RH / ARC / BASE / BNB) like the original
- [x] Explore "All" merges every enabled chain; rows carry their chain badge
- [x] Token pages `/token/{rh,arc,base,bnb}/ADDRESS` per chain (route exists; views use `current_chain` from the URL)
- [x] Stats per chain + "All chains" (USD totals)
- [x] Trade/launch/claim on Arc: USDC reference → approvals, `*WithReference` router entry points — launch + opening buy and approved buys verified with eth_call on the real Arc RPC
- [ ] Verified quote lists per chain (from the archive where it has rows)
- [x] Portfolio across chains

## 2. Missing indexer API endpoints (par-sdk INTEGRATION.md A8/A9)
- [x] `/distributions?token=` and `/rewards?owner=` — PairPadDisperse(V2) `Dispersed` / `Paid`; v1 per-wallet amounts from the tx Transfer logs (`Par::Extras`, own cursor `extras_cursor`)
- [x] `/floor?token=` — PairPadFloorVault `WallMoved`; launch rows carry `floor[]`
- [x] `/events` — server-sent events, one `batch` per indexed range (5-minute streams, resume via Last-Event-ID)
- [x] `/resolve?id=` and `/t/<16 hex>` — from the `/t/<id>` link par.family wrote into each token's website field
- [x] `/burns` in the par-sdk `FeeBurns` shape (burn-vault rounds only)

## 3. Keeper (permissionless upkeep the team's bots used to do)
- [!] `collectFees` for launches with meaningful pending fees (needs a funded keeper key — user decision)
- [!] FloorVault `rebalance`; BurnVault `burnToken` → then re-enable floor mode (`PAR_ALLOW_FLOOR_MODE=1`)

## 4. Page features the original had
- [x] Create: drag & drop / paste image with preview, "Stocks" quick pick (RH/Base/BNB via stocksonchain.io, Arc via longstocks.io, priceability from the on-chain pricer), token search by name/ticker/address (`/api/stocks`, `/api/tokens`)
- [x] Images on our own IPFS node (kubo accessory, 512 MB cap): `PinLogosJob` copies the original 2,940 logos off Pinata as CARs (same CIDs), `/ipfs/<cid>` serves them (falls back to the Pinata gateway), uploads pin to the node. Hourly `BackupPinsJob` copies each pin as a CAR to R2 bucket `par-mirror-ipfs` (token `par-mirror-backup`: that bucket only, server IP only; keys in 1Password Personal/par-mirror R2)
- [x] Stats: "Copy as text", holder payouts + wallets-paid charts, fee split section, leaderboards (volume, fees, holder payouts), per-chain cards, wallet counts
- [x] Token page: holder-reward rounds (+ connected wallet's own rewards), burns list with burner labels, floor wall card + history
- [x] Live updates: pages poll the cached `/idx/:chain/pulse` every 5 s (paused in background tabs); the token page swaps its `[data-live]` blocks when the token traded (new rows flash), Explore offers "N new tokens launched · show". `/events` streams capped per process (`PAR_MAX_SSE_STREAMS`, default 1) since each holds a web thread
- [x] Profiles: Sign-In with Ethereum (EIP-4361, server-written message, signature recovered in plain Ruby, EOAs only), `/profile` name/bio/image/links shown next to addresses and on the portfolio; the deployer or creator-fee recipient can correct a token's description/image/links on the mirror (marked as edited)

- [x] Languages (2026-11-09): English, 简体中文, 繁體中文 on every page except the archived Docs. Locale from a cookie (`/locale/:code`, header menu) or the browser's Accept-Language; Stimulus strings come from the `js.*` keys rendered into the page. Edit `config/locales/zh-CN.yml`, then `bin/i18n-zh-tw` regenerates zh-TW (OpenCC s2twp + term fixes); `bin/i18n-check` verifies every key exists in every locale

## 4b. MCP for AI agents
- [x] Read-only MCP server at `/mcp` (2026-11-09): official `mcp` gem 1.9, stateless Streamable HTTP, one class per tool in `app/mcp_tools/` (same layout as Pickful and smarts), per-IP rate limit, hosts follow `config.hosts`; `test/integration/mcp_test.rb`
- [x] Trading for agent wallets (2026-11-09): `quote_trade` simulates a buy/sell with eth_call (sells override the token's balance/allowance slots, so any wallet can be quoted; Arc buys need a real USDC approval first) and keeps the quote 60 s; `build_trade` re-simulates, refuses if the output fell below the quote's minimum, and returns unsigned txs (exact-amount approval, then the trade with that minimum encoded). Price impact is measured against a 1/1000 probe, not the last trade price (a stale or gap-adjacent last price showed 13% for a $5 buy). Same paths as par-sdk trade.ts (`Par::Trading`); the full ABI encoder is pinned to viem output (`test/lib/par/abi_encode_test.rb`). The server never signs, holds keys or broadcasts
- [ ] Next: `build_launch_tx`, `build_claim_tx`

## 5. Quality
- [x] End-to-end test `test/e2e/fork_e2e.mjs`: launch (1 pair and 2 markets) → buy → sell → collectFees → claim native + claimToken, through the real routers on anvil forks of RH and Base (all pass). Use a fresh key: anvil's public test accounts carry EIP-7702 sweeper delegations on mainnet. Arc can't run on anvil (USDC precompile) → `arc_launch_sim.mjs` / `arc_trade_sim.mjs` simulate with eth_call on the real RPC: launch + USDC opening buy OK, quote + buy OK once approved
- [x] Fixed (found by the e2e test): Arc buy quotes need a wallet that has approved USDC, so the trade box now shows "Approve USDC" first; and no chain sends a trade without a quote any more (it used to fall back to minimum received = 0)
- [ ] Dark-mode visual check

## Cannot be restored without the original team
Holder-reward payouts (team distributor wallet), BurnVault quote-side buyback (operator), X/GitHub creator
account claims (team attester), protocol fees and factory ownership, $par buyback bot, par.family domain.
