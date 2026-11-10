# par community mirror

A community-run replacement for the par.family website (offline since late 2026), rebuilt from the
open-source par contracts and SDK. It reads the **same, still-live contracts** on Robinhood Chain:
every existing token, pool and fee balance keeps working, and every transaction is signed in the
user's own wallet. The mirror holds no keys, no admin rights and earns no protocol fees.

Rails 8 · PostgreSQL · Solid Queue · Hotwire (Turbo + Stimulus) · viem + par-sdk in the browser · Kamal.

## What it does

| Page | |
|---|---|
| Explore `/` | every par launch; trending / market cap / new / volume / last trade; search by name, ticker, address |
| Token `/token/rh/:token` | price, market cap, volume, holders, burned; candles (1m–1d, USD or ETH); trades, holders, market info; buy/sell through par's routers (single and multi-market, ETH-routed); uncollected fees + permissionless `collectFees` |
| Create `/launch` | launch a token on 1–5 pairs (ETH, USDG, $par or any priceable token) with creator tax and an atomic opening buy |
| Portfolio `/portfolio?owner=0x…` | holdings with value and buy/sell flow, launched tokens, creator fees waiting in the escrow with claim buttons |
| Stats `/stats` | totals, daily volume, launches per day, fee modes, $par buybacks |
| Docs `/docs` | archived copy of the original docs |
| API `/idx/rh/…` | same endpoints and shapes as the original public indexer (par-sdk `INTEGRATION.md` A8): `health launches launches/count launches/:token trades candles holders positions fees burns buybacks stats tokenlist.json`, plus `claimable` |
| MCP `/mcp` | public MCP server (Streamable HTTP, stateless) for AI agents: 20 tools: the same data (`list_chains`, `search_tokens`, `get_token`, trades, candles, holders, positions, fees, claimable, burns, floor, holder payouts, rewards, $par buybacks, stats, short links) plus `quote_trade` → `build_trade`, `build_launch` and `build_claim_fees`, which return unsigned transactions for an agent's own wallet to sign. No auth, 60 requests per minute per IP (`PAR_MCP_RPM`); the server never signs, holds keys or sends transactions. Tools live in `app/mcp_tools/` |

## How it works

```
Robinhood Chain RPC ──eth_getLogs──▶ SyncChainJob (Solid Queue) ──▶ PostgreSQL ──▶ pages + /idx API
                                     Par::Indexer                                     │
browser ── viem + par-sdk ── quotes (eth_call) / transactions (user's wallet) ◀───────┘
```

* `app/lib/par/indexer.rb` replays par's history in 100k-block ranges from the factory deploy block:
  factory/locker logs → launches, markets, fee collections; PoolManager `Swap` logs filtered by par
  pool ids → trades and market aggregates; `Transfer` logs of par tokens → balances and burns.
  Everything a range writes is committed together with the cursor, so a crash never double counts.
* `app/lib/par/abi.rb` is a small ABI codec (no native crypto dependency); `rpc.rb` throttles requests,
  backs off on rate limits and batches reads through Multicall3.
* Trader = the address the PoolManager paid the tokens to (buy) or took them from (sell), followed
  through routers; routing hops fall back to `tx.from` (filled in the background).
* Block times are sampled every 10k blocks and interpolated (Robinhood Chain blocks are regular:
  ≤ 10 s error, 0.7 s on average); launch times are exact.
* Prices in ETH: quotes that are par tokens use their own last price; other quotes are priced through
  the on-chain `PairPadQuotePricer`; USD via the pricer's USDG anchor.

### Verified

`script/compare_with_bun.rb` cross-checks this index against an independent TypeScript indexer built
on par-sdk and against the original indexer's archived catalogue. Up to block 66,490,473: 1,148
launches, 1,379 markets, 207,958 trades and 12,774 balances identical to the unit; names, deployers,
pool ids, launch txs and launch times identical to the archive.

## Run locally

```bash
bin/setup                  # gems, bun packages, databases
bin/dev                    # web + JS build watcher (Procfile.dev)
bin/jobs                   # Solid Queue: chain sync (first full replay ≈ 1 h on the public RPC)
bin/rails test             # ABI codec and trader derivation tests
bin/fork-test              # send the pages' and the MCP's transactions on local anvil forks of
                           # Robinhood Chain and Base, check the results (needs Foundry; chains indexed)
bin/par-data status        # sync position
```

## Deploy (Kamal)

1. Fill the `TODO`s in `config/deploy.yml` (server, domain, registry) and export `POSTGRES_PASSWORD`
   (and optionally `PINATA_JWT` for image uploads) for `.kamal/secrets`.
2. `bin/kamal setup` — boots Postgres (accessory), web and the `job` role (`bin/jobs`).
3. Reuse a local sync instead of replaying history on the server:
   ```bash
   bin/par-data export          # consistent snapshot of the chain tables (data + cursor)
   bin/par-data push            # stop job role → copy → restore in one transaction → start job role
   ```
   The server resumes syncing from the imported cursor.
4. `bin/kamal sync` shows the server's sync position.

Useful environment: `PAR_RPC_URL_4663` (a private RPC makes the first sync much faster),
`PAR_RPS_4663` (request rate ceiling), `PAR_CHAINS` (default `4663`; Arc/Base/BNB are configured
but untested), `PAR_PUBLIC_RPC_4663` (RPC handed to browsers), `PAR_IPFS_GATEWAY`.

## Limits — what the mirror cannot restore

These depended on the original team's keys or bots:

* **Fees to holders**: the holder vault forwards fees to the team's distributor wallet, which paid
  holders hourly. Not launchable here; affected tokens show a notice.
* **Buyback & burn**: the token-side burn is open to anyone, the quote-side buyback is operator-only.
  Not launchable here; affected tokens show a notice.
* **Floor mode**: `rebalance` is open to anyone, so it can work again once this mirror runs a keeper
  (`PAR_ALLOW_FLOOR_MODE=1` re-enables it on the launch page).
* **Fees to an X / GitHub account**: claiming needs the team's attester signature; the funds are safe
  but locked until then.
* **Protocol fees** of existing tokens (and of new launches through the existing factories) still go
  to the original team's fee splitter; the factory owner can still change terms or close launching.
* Profiles (names, bios), Fomo payouts and the team's $par buyback bot.

Not built yet: automatic keeper, `/distributions` `/rewards` `/floor` `/events` endpoints, live
trade streaming, multi-chain UI.

## License

MIT, see [LICENSE](LICENSE). par's contracts and SDK are MIT too. This is an independent community mirror,
not affiliated with the par.family team; use it at your own risk.
