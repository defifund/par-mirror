// Arc, real RPC, eth_call only: quote + buy + sell from a wallet that has approved the router (what the trade box now requires)
import { createPublicClient, http, defineChain, formatUnits } from "viem"
import { erc20Abi, getLaunch, getEthRoutes, quoteBuyWithEth, quoteSellToEth, buildBuyWithEth, buildSellToEth, withSlippage } from "par-sdk"
const rpc = "https://rpc.mainnet.arc.io"
const pc = createPublicClient({ chain: defineChain({ id: 5042, name: "arc", nativeCurrency: { name: "USDC", symbol: "USDC", decimals: 18 }, rpcUrls: { default: { http: [rpc] } } }), transport: http(rpc) })
const [token, user] = process.argv.slice(2)
const launch = await getLaunch(pc, token, 5042), routes = await getEthRoutes(pc, launch, 5042)
const al = await pc.readContract({ address: "0x3600000000000000000000000000000000000000", abi: erc20Abi, functionName: "allowance", args: [user, launch.router] })
console.log(`router ${launch.router} · ${user} allowance ${al > 10n ** 30n ? "max" : al}`)
const amt = 1_000_000n
const q = await quoteBuyWithEth(pc, launch, routes, amt, undefined, 5042, user)
console.log(`quote buy 1 USDC: ${formatUnits(q, 18)} tokens`)
const b = buildBuyWithEth(launch, routes, amt, withSlippage(q, 300), user, undefined, 5042)
try { await pc.call({ account: user, to: b.to, data: b.data, value: b.value ?? 0n }); console.log("simulate buy with min = quote − 3%: OK") } catch (e) { console.log("simulate buy: REVERT " + (e.shortMessage || e.message).split("\n")[0]) }
const qs = await quoteSellToEth(pc, launch, routes, q / 2n, user, undefined, 5042)
console.log(`quote sell half of that: ${formatUnits(qs, 6)} USDC (the sell quote overrides balance + allowance, so it works for any wallet)`)
