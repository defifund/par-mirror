// The token page's buy/sell box (app/javascript/controllers/trade_controller.js), step for step, on a local anvil
// fork: getLaunch + getEthRoutes, quote as the wallet, min = quote - slippage (the box's default 3%), approve the
// token for the router before a sell, sign and send. Checks what arrived. Run through bin/fork-test (FORK_RPC = the
// fork). Robinhood Chain only; keep in step with trade_controller.js when the box changes.
import { createPublicClient, createWalletClient, http, defineChain, formatUnits, toHex } from "viem"
import { privateKeyToAccount, generatePrivateKey } from "viem/accounts"
import { getLaunch, getEthRoutes, quoteBuyWithEth, quoteSellToEth, buildBuyWithEth, buildSellToEth, buildApprove, withSlippage, erc20Abi } from "par-sdk"

const RPC = process.env.FORK_RPC
if (!/^http:\/\/127\.0\.0\.1:\d+$/.test(RPC || "")) { console.error("refusing to run: FORK_RPC must be a local fork"); process.exit(2) }
const chain = defineChain({ id: 4663, name: "rh fork", nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } })
// a fresh key per run, funded on the fork (anvil's dev account #0 sweeps any ETH it receives on this chain)
const account = privateKeyToAccount(generatePrivateKey())
const pc = createPublicClient({ chain, transport: http() })
const wc = createWalletClient({ chain, account, transport: http() })
await pc.request({ method: "anvil_setBalance", params: [account.address, toHex(10n ** 19n)] })
const me = account.address
const SLIP = 300 // trade_controller.js default
const TOKENS = [["single-market token ($par)", "0x507B6F349a80114097A67B8b4677367acC15b220"],
                ["multi-market token", process.env.FORK_MULTI_TOKEN || "0x9bbd4d06ac29d8900b34998a56e96a33c16220f0"]]

let fails = 0
const check = (label, ok, detail = "") => { console.log(`${ok ? "ok  " : "FAIL"} ${label}${detail ? ` (${detail})` : ""}`); if (!ok) fails++ }
const fmt = (v, d = 18) => Number(formatUnits(v, d)).toFixed(4)
const send = async (tx) => {
  try { return (await pc.waitForTransactionReceipt({ hash: await wc.sendTransaction({ ...tx, gas: 3_000_000n }) })).status === "success" } catch { return false }
}
const tokenBal = (token) => pc.readContract({ address: token, abi: erc20Abi, functionName: "balanceOf", args: [me] })

for (const [kind, token] of TOKENS) {
  const launch = await getLaunch(pc, token, chain.id)
  const routes = await getEthRoutes(pc, launch, chain.id)
  const amount = 10n ** 15n

  // buy: quote as the wallet, floor at the slippage, send
  const q = await quoteBuyWithEth(pc, launch, routes, amount, undefined, chain.id, me)
  const min = withSlippage(q, SLIP)
  let before = await tokenBal(token)
  let ok = await send(buildBuyWithEth(launch, routes, amount, min, me, undefined, chain.id))
  const got = (await tokenBal(token)) - before
  check(`buy ${kind}`, ok && got >= min, `quoted ${fmt(q)}, min ${fmt(min)}, received ${fmt(got)}`)
  if (!ok || got === 0n) continue

  // sell it all back: approveIfNeeded, then quote, floor, send
  const allowance = await pc.readContract({ address: token, abi: erc20Abi, functionName: "allowance", args: [me, launch.router] })
  if (allowance < got) check(`approve ${kind} for the router`, await send(buildApprove(token, launch.router)))
  const qs = await quoteSellToEth(pc, launch, routes, got, me, undefined, chain.id)
  const minS = withSlippage(qs, SLIP)
  before = await pc.getBalance({ address: me })
  const hash = await wc.sendTransaction({ ...buildSellToEth(launch, routes, got, minS, me, undefined, chain.id), gas: 3_000_000n }).catch(() => null)
  const r = hash && await pc.waitForTransactionReceipt({ hash })
  const back = r ? (await pc.getBalance({ address: me })) - before + r.gasUsed * r.effectiveGasPrice : 0n
  check(`sell ${kind} back`, r?.status === "success" && back >= minS && (await tokenBal(token)) === 0n, `quoted ${fmt(qs)} ETH, min ${fmt(minS)}, received ${fmt(back)}`)

  // a minimum above what the pool gives must revert, not fill at a worse price
  check(`buy ${kind} with an unreachable minimum reverts`, !(await send(buildBuyWithEth(launch, routes, amount, q * 2n, me, undefined, chain.id))))
}
console.log(fails ? `trade box: ${fails} failed` : "trade box: all passed")
process.exit(fails ? 1 : 0)
