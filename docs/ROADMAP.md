# Roadmap: full feature parity with the original par.family

Goal (user, 2026-11-08): restore every feature the original site had, across all four chains.
Status legend: [x] done · [~] in progress · [ ] to do · [!] blocked on the user

## 1. Multi-chain (original: one app for Robinhood Chain, Arc, Base, BNB Chain)
- [~] Index Base (8453): public RPC base-rpc.publicnode.com, ≤10 addresses per getLogs → `max_addresses: 10`
- [~] Index Arc (5042): public RPC rpc.mainnet.arc.io, log span 2k (20k-result cap), ≤20 addresses per getLogs; reference asset is USDC (ERC-20, 6 decimals, USD = 1)
- [ ] Index BNB Chain (56): no keyed RPC (user has none) → degraded mode: seed the 29 archived launches, follow from the head via publicnode (≤10 addresses); history later via a free Etherscan V2 key if the user gets one
- [x] Chain switcher in the header; chain tabs on Explore (All / RH / ARC / BASE / BNB) like the original
- [x] Explore "All" merges every enabled chain; rows carry their chain badge
- [x] Token pages `/token/{rh,arc,base,bnb}/ADDRESS` per chain (route exists; views use `current_chain` from the URL)
- [x] Stats per chain + "All chains" (USD totals)
- [~] Trade/launch/claim on Arc: USDC reference → approvals, `*WithReference` router entry points
- [ ] Verified quote lists per chain (from the archive where it has rows)
- [x] Portfolio across chains

## 2. Missing indexer API endpoints (par-sdk INTEGRATION.md A8/A9)
- [x] `/distributions?token=` and `/rewards?owner=` — PairPadDisperse(V2) `Dispersed` / `Paid`; v1 per-wallet amounts from the tx Transfer logs (`Par::Extras`, own cursor `extras_cursor`)
- [x] `/floor?token=` — PairPadFloorVault `WallMoved`; launch rows carry `floor[]`
- [x] `/events` — server-sent events, one `batch` per indexed range (5-minute streams, resume via Last-Event-ID)
- [x] `/resolve?id=` and `/t/<16 hex>` — from the `/t/<id>` link par.family wrote into each token's website field
- [x] `/burns` in the par-sdk `FeeBurns` shape (burn-vault rounds only)

## 3. Keeper (permissionless upkeep the team's bots used to do)
- [ ] `collectFees` for launches with meaningful pending fees (needs a funded keeper key — user decision)
- [ ] FloorVault `rebalance`; BurnVault `burnToken` → then re-enable floor mode (`PAR_ALLOW_FLOOR_MODE=1`)

## 4. Page features the original had
- [ ] Create: drag & drop / paste image, "Stocks" quick-pick category, token search by name for the pair
- [ ] Stats: "Copy as text", holder payouts chart, fee split section
- [x] Token page: holder-reward rounds (+ connected wallet's own rewards), burns list with burner labels, floor wall card + history
- [ ] Live updates (Turbo Streams from the sync job) instead of polling
- [ ] Profiles (name / bio next to an address) — originally team-hosted; rebuild as wallet-signed (SIWE) profiles

## 5. Quality
- [ ] Anvil-fork end-to-end test: launch → buy → sell → collect → claim through the real routers
- [ ] Dark-mode visual check

## Cannot be restored without the original team
Holder-reward payouts (team distributor wallet), BurnVault quote-side buyback (operator), X/GitHub creator
account claims (team attester), protocol fees and factory ownership, $par buyback bot, par.family domain.
