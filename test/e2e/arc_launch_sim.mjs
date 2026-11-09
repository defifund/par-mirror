// Simulates the Arc USDC flows with plain eth_call on the real Arc RPC (nothing is sent, no signature):
// from real users who already approved USDC to the par routers and still hold enough USDC.
import { readFileSync } from "node:fs"
import { createPublicClient, http, encodeFunctionData, toHex, defineChain, decodeFunctionResult, formatUnits } from "viem"
import { multiFactoryAbi, multiRouterAbi, erc20Abi, getEthRoute, buildLegs, getLaunch, getEthRoutes, quoteBuyWithEth, quoteSellToEth, buildBuyWithEth, buildSellToEth, withSlippage } from "par-sdk"
const rpc = "https://rpc.mainnet.arc.io"
const cfg = (await (await fetch("http://localhost:3000/api/config")).json()).chains.find((c) => c.id === 5042)
const a = cfg.addresses, ref = cfg.reference
const pc = createPublicClient({ batch: { multicall: true }, chain: defineChain({ id: 5042, name: "arc", nativeCurrency: { name: "USDC", symbol: "USDC", decimals: 18 }, rpcUrls: { default: { http: [rpc] } }, contracts: { multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" } } }), transport: http(rpc) })
const addrs = JSON.parse(readFileSync(process.argv[2]))
const fee = await pc.readContract({ address: a.multiFactory, abi: multiFactoryAbi, functionName: "launchFee" })
const read = (fn, args) => pc.readContract({ address: ref.address, abi: erc20Abi, functionName: fn, args }).catch(() => 0n)
const rows = []
for (let i = 0; i < addrs.length; i += 100) {
  const slice = addrs.slice(i, i + 100)
  const res = await Promise.all(slice.map(async (u) => ({ u, bal: await read("balanceOf", [u]), alMulti: await read("allowance", [u, a.multiRouter]), alRouter: await read("allowance", [u, a.router]) })))
  rows.push(...res)
}
const BUY = 1_000_000n // 1 USDC
const launcher = rows.find((r) => r.alMulti >= BUY && r.bal > BUY + fee / 10n ** 12n + 1_000_000n)
const trader = rows.find((r) => r.alRouter >= BUY && r.bal > BUY + 1_000_000n) || rows.find((r) => r.alMulti >= BUY && r.bal > BUY + 1_000_000n)
console.log(`checked ${rows.length} addresses · launcher candidate: ${launcher?.u ?? "none"} · trader candidate: ${trader?.u ?? "none"}`)

const call = async (from, to, data, value = 0n) => {
  try { const r = await pc.call({ account: from, to, data, value }); return { ok: true, data: r.data } }
  catch (e) { return { ok: false, err: (e.shortMessage || e.message).split("\n")[0] } }
}
if (launcher) {
  const legs = buildLegs({ markets: [{ index: 0 }] }, [await getEthRoute(pc, ref.address, 5042)], BUY, "buy")
  const params = { name: "sim", symbol: "SIM", logo: "", description: "", socials: { twitter: "", telegram: "", discord: "", website: "", farcaster: "" },
    creatorFeeRecipient: launcher.u, creatorTaxBps: 100, expectedEconomics: "0x" + "0".repeat(64), salt: toHex(crypto.getRandomValues(new Uint8Array(24))) + "5041524d49525231" }
  const r = await call(launcher.u, a.multiRouter, encodeFunctionData({ abi: multiRouterAbi, functionName: "launchAndBuyWithReference", args: [params, 0n, [ref.address], legs, BUY, 0n] }), fee)
  console.log(`launchAndBuyWithReference (1 USDC opening buy) from ${launcher.u}: ${r.ok ? "OK" : "REVERT " + r.err}`)
}
// buy + sell on the most-traded Arc token, through the same SDK builders as the trade box
const token = process.argv[3]
const launch = await getLaunch(pc, token, 5042)
const routes = await getEthRoutes(pc, launch, 5042)
if (trader) {
  const q = await quoteBuyWithEth(pc, launch, routes, BUY, undefined, 5042, trader.u)
  const tx = buildBuyWithEth(launch, routes, BUY, withSlippage(q, 300), trader.u, undefined, 5042)
  const needs = await read("allowance", [trader.u, launch.router])
  const r = needs >= BUY ? await call(trader.u, tx.to, tx.data, tx.value ?? 0n) : { ok: false, err: `trader has no allowance to ${launch.router}` }
  console.log(`buy 1 USDC of ${token} via ${launch.router} from ${trader.u}: quoted ${formatUnits(q, 18)} tokens · ${r.ok ? "OK" : "REVERT " + r.err}`)
}
// sell: from a real holder of the token who approved the router
const holders = await (await fetch(`http://localhost:3000/idx/5042/holders?token=${token}&limit=50`)).json()
for (const h of (holders.holders || holders.items || holders).slice?.(0, 50) ?? []) {
  const owner = h.owner || h.address; if (!owner) continue
  const bal = await pc.readContract({ address: token, abi: erc20Abi, functionName: "balanceOf", args: [owner] })
  const al = await pc.readContract({ address: token, abi: erc20Abi, functionName: "allowance", args: [owner, launch.router] })
  const amt = bal / 10n
  if (amt === 0n || al < amt) continue
  const q = await quoteSellToEth(pc, launch, routes, amt, owner, undefined, 5042)
  const tx = buildSellToEth(launch, routes, amt, withSlippage(q, 300), owner, undefined, 5042)
  const r = await call(owner, tx.to, tx.data)
  console.log(`sell 10% of ${owner}'s ${token}: quoted ${formatUnits(q, 6)} USDC · ${r.ok ? "OK" : "REVERT " + r.err}`)
  break
}
