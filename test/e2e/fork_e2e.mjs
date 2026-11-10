// End-to-end test against anvil forks of the live chains: every transaction flow the mirror's pages send,
// built exactly the way the Stimulus controllers build them (same par-sdk calls, same ABIs, same routers).
// Run it through bin/fork-test, which starts the forks and writes the chain config; by hand:
//
//   anvil --fork-url https://rpc.mainnet.chain.robinhood.com --port 8601
//   anvil --fork-url https://base-rpc.publicnode.com          --port 8602
//   node test/e2e/fork_e2e.mjs [rh,base]   (FORK_CONFIG = a saved /api/config, else the dev server on :3000;
//                                           FORK_RPC_<slug> overrides the ports above)
//
// Arc cannot run here: its USDC is backed by a system precompile (0x1800…0001) that anvil does not have, so every
// USDC transfer reverts with "invalid opcode" in a fork. Arc is checked with eth_call against the real RPC instead:
//   node test/e2e/arc_launch_sim.mjs <addresses.json> <token>   launchAndBuyWithReference from a real approved wallet
//   node test/e2e/arc_trade_sim.mjs <token> <approved wallet>   quote + buy + sell quote
//
// Uses a throwaway key generated per run, funded with anvil_setBalance inside the fork.
import { createPublicClient, createWalletClient, http, parseAbi, parseEther, parseUnits, formatUnits, encodeFunctionData,
         decodeEventLog, decodeFunctionResult, zeroAddress, toHex, defineChain } from "viem"
import { privateKeyToAccount, generatePrivateKey } from "viem/accounts"
import { factoryAbi, multiFactoryAbi, multiRouterAbi, lockerAbi, multiLockerAbi, feeEscrowAbi, erc20Abi,
         getLaunch, getEthRoute, getEthRoutes, buildLegs, quoteBuyWithEth, quoteSellToEth, buildBuyWithEth, buildSellToEth,
         buildApprove, withSlippage } from "par-sdk"

const routerAbi = parseAbi([ // copied from app/javascript/controllers/create_controller.js
  "struct Socials { string twitter; string telegram; string discord; string website; string farcaster; }",
  "struct TokenParams { string name; string symbol; string logo; string description; Socials socials; address creatorFeeRecipient; uint16 creatorTaxBps; bytes32 expectedEconomics; bytes32 salt; }",
  "struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }",
  "struct Hop { PoolKey key; bool v3; }",
  "function launchAndBuyWithEth(TokenParams params, uint256 launchConfigId, address pairToken, Hop[] leg, uint256 minTokensOut) payable returns (address token, bytes32 poolId, uint256 tokensOut)",
])
const escrowViews = parseAbi(["function balanceOf(address) view returns (uint256)", "function balanceOfToken(address,address) view returns (uint256)"])
const MIRROR_TAG = "5041524d49525231"
// A fresh key every run, funded only inside the fork. (anvil's well-known test accounts are useless here:
// their keys are public, so on mainnet they carry EIP-7702 sweeper delegations that forward any ETH they receive.)
const KEY = generatePrivateKey()
const PORTS = { rh: 8601, base: 8602, arc: 8603 }
const SLIP = 300              // trade_controller.js default
const LAUNCH_SLIP = 100n       // create_controller.js LAUNCH_SLIPPAGE_BPS

const results = []
function record(chain, step, ok, detail) {
  results.push({ chain, step, ok, detail })
  console.log(`${ok ? "PASS" : "FAIL"}  ${chain.padEnd(4)} ${step.padEnd(34)} ${detail}`)
}

async function main() {
  const only = (process.argv[2] || "rh,base").split(",")
  if (only.includes("arc")) console.log("arc: skipped — anvil cannot emulate Arc's USDC precompile; use test/e2e/arc_*_sim.mjs")
  const { readFileSync } = await import("node:fs")
  const cfg = process.env.FORK_CONFIG ? JSON.parse(readFileSync(process.env.FORK_CONFIG, "utf8")) : await (await fetch("http://localhost:3000/api/config")).json()
  for (const ci of cfg.chains) {
    if (!only.includes(ci.slug) || !PORTS[ci.slug] || ci.slug === "arc") continue
    try { await runChain(ci) } catch (e) { record(ci.slug, "(aborted)", false, short(e)) }
  }
  const failed = results.filter((r) => !r.ok)
  console.log(`\n${results.length - failed.length}/${results.length} steps passed`)
  process.exit(failed.length ? 1 : 0)
}

async function runChain(ci) {
  const rpc = process.env[`FORK_RPC_${ci.slug}`] || `http://127.0.0.1:${PORTS[ci.slug]}`
  const chain = defineChain({ id: ci.id, name: ci.name, nativeCurrency: { name: "native", symbol: "NAT", decimals: 18 }, rpcUrls: { default: { http: [rpc] } } })
  const pc = createPublicClient({ chain, transport: http(rpc) })
  const account = privateKeyToAccount(KEY)
  const wc = createWalletClient({ chain, transport: http(rpc), account })
  const me = account.address
  const a = ci.addresses, ref = ci.reference
  const S = ci.slug

  // every tx goes through here: send, wait, fail loudly on revert, return receipt + gas paid in native
  const send = async (tx) => {
    const hash = await wc.sendTransaction({ to: tx.to, data: tx.data, value: tx.value ?? 0n })
    const r = await pc.waitForTransactionReceipt({ hash })
    if (r.status !== "success") {
      const why = await pc.call({ account: me, to: tx.to, data: tx.data, value: tx.value ?? 0n, blockNumber: r.blockNumber - 1n }).then(() => "?", (e) => short(e))
      throw new Error(`reverted ${hash.slice(0, 10)}: ${why}`)
    }
    return { ...r, gasPaid: r.gasUsed * r.effectiveGasPrice }
  }
  const reverts = async (tx) => send(tx).then(() => false, () => true)
  // the create form: simulate the whole launch as the wallet, floor the opening buy at simulated tokens - 1%, send
  // (txFor(min) builds the launch for a given minimum). Also checks that a minimum above the simulation reverts.
  const launchFloored = async (label, abi, fn, txFor) => {
    const sim = txFor(0n)
    const { data } = await pc.call({ account: me, to: sim.to, data: sim.data, value: sim.value })
    const out = decodeFunctionResult({ abi, functionName: fn, data })
    const tokensOut = out[out.length - 1]
    const min = (tokensOut * (10_000n - LAUNCH_SLIP)) / 10_000n
    record(S, `${label}: min too high reverts`, await reverts(txFor(tokensOut * 2n)), `min ${fmt(tokensOut * 2n, 18)} = 2 × simulated`)
    return { r: await send(txFor(min)), tokensOut, min }
  }
  const nativeBal = () => pc.getBalance({ address: me })
  const erc20Bal = (t) => pc.readContract({ address: t, abi: erc20Abi, functionName: "balanceOf", args: [me] })
  const refBal = () => (ref.native ? nativeBal() : erc20Bal(ref.address))
  const approve = async (asset, spender, amount) => {
    const al = await pc.readContract({ address: asset, abi: erc20Abi, functionName: "allowance", args: [me, spender] })
    if (al < amount) await send(buildApprove(asset, spender))
  }
  const launchedToken = (receipt, multi) => {
    for (const l of receipt.logs) {
      try {
        const ev = decodeEventLog({ abi: multi ? multiFactoryAbi : factoryAbi, data: l.data, topics: l.topics })
        if (ev.eventName === "TokenLaunched") return ev.args.token
      } catch {}
    }
    return null
  }
  const params = (tag) => ({
    name: `E2E ${S} ${tag}`, symbol: `E2E${tag.toUpperCase()}`, logo: "", description: "fork test, never on mainnet",
    socials: { twitter: "", telegram: "", discord: "", website: "", farcaster: "" },
    creatorFeeRecipient: me, creatorTaxBps: 100, expectedEconomics: "0x" + "0".repeat(64),
    salt: toHex(crypto.getRandomValues(new Uint8Array(24))) + MIRROR_TAG,
  })

  await pc.request({ method: "anvil_setBalance", params: [me, toHex(parseEther("1000"))] })
  if (((await pc.getCode({ address: me })) ?? "0x") !== "0x") throw new Error("test account has code (EIP-7702?) — use a fresh key")

  console.log(`\n== ${ci.name} (${ci.id}) · reference ${ref.symbol}${ref.native ? " (native)" : " (ERC-20)"} · fork block ${await pc.getBlockNumber()}`)
  const startRef = await refBal()
  console.log(`   test account ${me}: ${fmt(startRef, ref.decimals)} ${ref.symbol}, native ${fmt(await nativeBal(), 18)}`)
  if (startRef === 0n) throw new Error(`test account has no ${ref.symbol} in the fork`)

  const fee = await pc.readContract({ address: a.factory, abi: factoryAbi, functionName: "launchFee" })
  const multiFee = await pc.readContract({ address: a.multiFactory, abi: multiFactoryAbi, functionName: "launchFee" })
  const unit = 10n ** BigInt(ref.decimals)
  const devBuy = ref.native ? parseEther("0.01") : 5n * unit // 0.01 ETH or 5 USDC
  const tokens = [] // [{ tag, token, multi }]

  // 1. single-pair launch with an opening buy (create page, one pair = the reference asset)
  try {
    let r, multi, sim
    if (ref.native) {
      const route = await getEthRoute(pc, ref.address, ci.id)
      sim = await launchFloored("launch 1 pair", routerAbi, "launchAndBuyWithEth", (min) => ({ to: a.router, value: fee + devBuy,
        data: encodeFunctionData({ abi: routerAbi, functionName: "launchAndBuyWithEth", args: [params("a"), 0n, ref.address, route?.buyHops ?? [], min] }) }))
      r = sim.r
      multi = false
    } else {
      // Arc: ERC-20 reference → always the multi router, opening buy pulled from an allowance
      const routes = [await getEthRoute(pc, ref.address, ci.id)]
      const legs = buildLegs({ markets: [{ index: 0 }] }, routes, devBuy, "buy")
      await approve(ref.address, a.multiRouter, devBuy)
      r = await send({ to: a.multiRouter, value: multiFee,
        data: encodeFunctionData({ abi: multiRouterAbi, functionName: "launchAndBuyWithReference", args: [params("a"), 0n, [ref.address], legs, devBuy, 0n] }) })
      multi = true
    }
    const token = launchedToken(r, multi)
    const held = token ? await erc20Bal(token) : 0n
    const floor = sim ? ` (simulated ${fmt(sim.tokensOut, 18)}, min ${fmt(sim.min, 18)})` : ""
    record(S, `launch 1 pair + opening buy`, !!token && held > 0n && (!sim || (sim.min > 0n && held >= sim.min)), `${token ?? "no TokenLaunched event"} · got ${fmt(held, 18)} tokens${floor} · gas ${r.gasUsed}`)
    if (token) tokens.push({ tag: "a", token, multi })
  } catch (e) { record(S, "launch 1 pair + opening buy", false, short(e)) }

  // 2. multi-market launch (reference + USDG), opening buy split over both legs (native chains)
  if (ref.native && a.usdg && a.usdg !== zeroAddress) {
    try {
      const pairs = [ref.address, a.usdg]
      const routes = await Promise.all(pairs.map((p) => getEthRoute(pc, p, ci.id)))
      const legs = buildLegs({ markets: pairs.map((_, i) => ({ index: i })) }, routes, devBuy, "buy")
      const sim = await launchFloored("launch 2 markets", multiRouterAbi, "launchAndBuyWithEth", (min) => ({ to: a.multiRouter, value: multiFee + devBuy,
        data: encodeFunctionData({ abi: multiRouterAbi, functionName: "launchAndBuyWithEth", args: [params("m"), 0n, pairs, legs, min] }) }))
      const token = launchedToken(sim.r, true)
      const held = token ? await erc20Bal(token) : 0n
      record(S, "launch 2 markets (ref + USDG) + buy", !!token && held >= sim.min && sim.min > 0n, `${token ?? "no TokenLaunched event"} · got ${fmt(held, 18)} tokens (simulated ${fmt(sim.tokensOut, 18)}, min ${fmt(sim.min, 18)})`)
      if (token) tokens.push({ tag: "m", token, multi: true })
    } catch (e) { record(S, "launch 2 markets (ref + USDG) + buy", false, short(e)) }
  }

  // 3–6 on each launched token: buy, sell half, collect fees, claim the creator share
  for (const { tag, token, multi } of tokens) {
    const launch = await getLaunch(pc, token, ci.id)
    if (!launch) { record(S, `[${tag}] getLaunch`, false, "SDK could not read the launch"); continue }
    const routes = await getEthRoutes(pc, launch, ci.id)

    // buy (trade box)
    try {
      const amt = ref.native ? parseEther("0.02") : 10n * unit
      const q = await quoteBuyWithEth(pc, launch, routes, amt, undefined, ci.id, me)
      const min = withSlippage(q, SLIP)
      if (!ref.native) await approve(ref.address, launch.router, amt)
      const before = await erc20Bal(token)
      await send(buildBuyWithEth(launch, routes, amt, min, me, undefined, ci.id))
      const got = (await erc20Bal(token)) - before
      record(S, `[${tag}] buy ${fmt(amt, ref.decimals)} ${ref.symbol}`, got >= min, `quoted ${fmt(q, 18)} · got ${fmt(got, 18)} (min ${fmt(min, 18)})`)
      record(S, `[${tag}] buy, min too high reverts`, await reverts(buildBuyWithEth(launch, routes, amt, q * 2n, me, undefined, ci.id)), "min = 2 × quote")
    } catch (e) { record(S, `[${tag}] buy`, false, short(e)) }

    // sell half (trade box)
    try {
      const amt = (await erc20Bal(token)) / 2n
      await approve(token, launch.router, amt)
      const q = await quoteSellToEth(pc, launch, routes, amt, me, undefined, ci.id)
      const min = withSlippage(q, SLIP)
      const before = await refBal()
      const r = await send(buildSellToEth(launch, routes, amt, min, me, undefined, ci.id))
      const got = (await refBal()) - before + (ref.native ? r.gasPaid : 0n)
      record(S, `[${tag}] sell half`, got >= min, `quoted ${fmt(q, ref.decimals)} · got ${fmt(got, ref.decimals)} ${ref.symbol} (min ${fmt(min, ref.decimals)})`)
    } catch (e) { record(S, `[${tag}] sell half`, false, short(e)) }

    // collectFees (fees card: anyone can call; single → locker, multi → multiLocker)
    try {
      const nBefore = await pc.readContract({ address: a.feeEscrow, abi: escrowViews, functionName: "balanceOf", args: [me] })
      const tBefore = await pc.readContract({ address: a.feeEscrow, abi: escrowViews, functionName: "balanceOfToken", args: [me, token] })
      await send({ to: multi ? a.multiLocker : a.locker,
        data: encodeFunctionData({ abi: multi ? multiLockerAbi : lockerAbi, functionName: "collectFees", args: [token] }) })
      const nAfter = await pc.readContract({ address: a.feeEscrow, abi: escrowViews, functionName: "balanceOf", args: [me] })
      const tAfter = await pc.readContract({ address: a.feeEscrow, abi: escrowViews, functionName: "balanceOfToken", args: [me, token] })
      const quoteSide = await escrowQuoteSide(pc, a.feeEscrow, me, ref, launch)
      const grew = nAfter > nBefore || tAfter > tBefore || quoteSide > 0n
      record(S, `[${tag}] collectFees → escrow`, grew, `escrow now: ${fmt(nAfter, 18)} native · ${fmt(tAfter, 18)} token${quoteSide ? ` · ${fmt(quoteSide, ref.decimals)} ${ref.symbol}` : ""}`)
    } catch (e) { record(S, `[${tag}] collectFees`, false, short(e)) }
  }

  // claim the creator share (portfolio page): native via claim(), every ERC-20 via claimToken(asset)
  try {
    const assets = [...new Set([...tokens.map((t) => t.token), ...(ref.native ? [] : [ref.address]), ...(a.usdg ? [a.usdg] : [])])]
    let claimed = 0
    const nOwed = await pc.readContract({ address: a.feeEscrow, abi: escrowViews, functionName: "balanceOf", args: [me] })
    if (nOwed > 0n) {
      const before = await nativeBal()
      const r = await send({ to: a.feeEscrow, data: encodeFunctionData({ abi: feeEscrowAbi, functionName: "claim", args: [] }) })
      const got = (await nativeBal()) - before + r.gasPaid
      const diff = got - nOwed // L2s add an L1 data fee outside gasUsed × price: allow < 1e12 wei (0.000001 ETH) of slack
      record(S, "claim native creator fees", (diff < 0n ? -diff : diff) < 10n ** 12n, `owed ${fmt(nOwed, 18)} · received ${fmt(got, 18)} · diff ${diff} wei`)
      claimed++
    }
    for (const asset of assets) {
      const owed = await pc.readContract({ address: a.feeEscrow, abi: escrowViews, functionName: "balanceOfToken", args: [me, asset] })
      if (owed === 0n) continue
      const before = await erc20Bal(asset)
      await send({ to: a.feeEscrow, data: encodeFunctionData({ abi: feeEscrowAbi, functionName: "claimToken", args: [asset] }) })
      const got = (await erc20Bal(asset)) - before
      const left = await pc.readContract({ address: a.feeEscrow, abi: escrowViews, functionName: "balanceOfToken", args: [me, asset] })
      record(S, `claimToken ${asset.slice(0, 8)}…`, got === owed && left === 0n, `owed ${fmt(owed, 18)} · received ${fmt(got, 18)} · left ${left}`)
      claimed++
    }
    if (!claimed) record(S, "claim creator fees", false, "nothing in the escrow to claim after collectFees")
  } catch (e) { record(S, "claim creator fees", false, short(e)) }
}

async function escrowQuoteSide(pc, escrow, me, ref, launch) {
  if (ref.native) return 0n
  return pc.readContract({ address: escrow, abi: escrowViews, functionName: "balanceOfToken", args: [me, ref.address] }).catch(() => 0n)
}

const fmt = (v, d) => Number(formatUnits(v, d)).toPrecision(5)
const short = (e) => (e?.shortMessage || e?.details || e?.message || String(e)).split("\n")[0].slice(0, 220)

main()
