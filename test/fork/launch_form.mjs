// The site's launch form (app/javascript/controllers/create_controller.js), step for step, on a local anvil fork:
// build the launch, simulate it as the wallet, floor the opening buy at simulated tokens - 1%, sign and send,
// read TokenLaunched from the receipt. Run through bin/fork-test (FORK_RPC = the fork). Robinhood Chain only.
// Keep in step with create_controller.js when the form changes.
import { createPublicClient, createWalletClient, http, encodeFunctionData, decodeFunctionResult, decodeEventLog, parseAbi, toHex, zeroAddress, defineChain, formatEther } from "viem"
import { privateKeyToAccount, generatePrivateKey } from "viem/accounts"
import { factoryAbi, multiFactoryAbi, multiRouterAbi, getEthRoute, buildLegs } from "par-sdk"

const RPC = process.env.FORK_RPC
if (!/^http:\/\/127\.0\.0\.1:\d+$/.test(RPC || "")) { console.error("refusing to run: FORK_RPC must be a local fork"); process.exit(2) }
const chain = defineChain({ id: 4663, name: "rh fork", nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } })
// a fresh key per run, funded on the fork. Not anvil's dev accounts: on Robinhood Chain #0 carries an EIP-7702
// delegation that sweeps any ETH it receives.
const account = privateKeyToAccount(generatePrivateKey())
const pc = createPublicClient({ chain, transport: http() })
await pc.request({ method: "anvil_setBalance", params: [account.address, toHex(10n ** 19n)] })
const wc = createWalletClient({ chain, account, transport: http() })
const A = { router: "0x73d84bdbB1983Fa7eD8FCBcE40bc308997cEd120", multiRouter: "0x458D2a59c2F3dd32775a64eE72004561440d64Df",
            factory: "0x9d33Ba78389c8772bC114Cba47Dc1985E933e76F", multiFactory: "0x3ea29975a79900179F3e1aEF93347Ba4210c29C1",
            par: "0x507B6F349a80114097A67B8b4677367acC15b220" }
const LAUNCH_SLIPPAGE_BPS = 100n, MIRROR_TAG = "5041524d49525231"
const routerAbi = parseAbi([
  "struct Socials { string twitter; string telegram; string discord; string website; string farcaster; }",
  "struct TokenParams { string name; string symbol; string logo; string description; Socials socials; address creatorFeeRecipient; uint16 creatorTaxBps; bytes32 expectedEconomics; bytes32 salt; }",
  "struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }",
  "struct Hop { PoolKey key; bool v3; }",
  "function launchAndBuyWithEth(TokenParams params, uint256 launchConfigId, address pairToken, Hop[] leg, uint256 minTokensOut) payable returns (address token, bytes32 poolId, uint256 tokensOut)",
])
const erc20 = parseAbi(["function balanceOf(address) view returns (uint256)"])
const feeAbi = parseAbi(["function launchFee() view returns (uint256)"])

let fails = 0
const check = (label, ok, detail = "") => { console.log(`${ok ? "ok  " : "FAIL"} ${label}${detail ? ` (${detail})` : ""}`); if (!ok) fails++ }
const fmt = (v) => Number(formatEther(v)).toFixed(4)

async function launch(pairs, buy, slippageBps = LAUNCH_SLIPPAGE_BPS) {
  const multi = pairs.length > 1
  const launchFee = await pc.readContract({ address: multi ? A.multiFactory : A.factory, abi: feeAbi, functionName: "launchFee" })
  const params = { name: "Fork form check", symbol: "FFORM", logo: "", description: "",
    socials: { twitter: "", telegram: "", discord: "", website: "", farcaster: "" },
    creatorFeeRecipient: account.address, creatorTaxBps: 0, expectedEconomics: "0x" + "0".repeat(64),
    salt: toHex(crypto.getRandomValues(new Uint8Array(24))) + MIRROR_TAG }
  let txFor, abi, fn = "launchAndBuyWithEth"
  if (!multi) {
    const route = await getEthRoute(pc, pairs[0], chain.id)
    abi = routerAbi
    txFor = (min) => ({ to: A.router, value: launchFee + buy, data: encodeFunctionData({ abi, functionName: fn, args: [params, 0n, pairs[0], route?.buyHops ?? [], min] }) })
  } else {
    const routes = await Promise.all(pairs.map((p) => getEthRoute(pc, p, chain.id)))
    const legs = buildLegs({ markets: pairs.map((_, i) => ({ index: i })) }, routes, buy, "buy")
    abi = multiRouterAbi
    txFor = (min) => ({ to: A.multiRouter, value: launchFee + buy, data: encodeFunctionData({ abi, functionName: fn, args: [params, 0n, pairs, legs, min] }) })
  }
  const sim = txFor(0n)
  const { data } = await pc.call({ account: account.address, to: sim.to, data: sim.data, value: sim.value })
  const out = decodeFunctionResult({ abi, functionName: fn, data })
  const tokensOut = out[out.length - 1]
  const min = (tokensOut * (10_000n - slippageBps)) / 10_000n
  const tx = txFor(min)
  let receipt
  try { receipt = await pc.waitForTransactionReceipt({ hash: await wc.sendTransaction({ ...tx, gas: 15_000_000n }) }) } catch { return { ok: false, tokensOut, min } }
  let token = null
  for (const l of receipt.logs) {
    try { const ev = decodeEventLog({ abi: multi ? multiFactoryAbi : factoryAbi, data: l.data, topics: l.topics }); if (ev.eventName === "TokenLaunched") { token = ev.args.token; break } } catch {}
  }
  const got = token ? await pc.readContract({ address: token, abi: erc20, functionName: "balanceOf", args: [account.address] }) : 0n
  return { ok: receipt.status === "success", token, tokensOut, min, got }
}

const buy = 10n ** 15n
for (const [label, pairs] of [["form launch, one market", [zeroAddress]], ["form launch, two markets (ETH + $par)", [zeroAddress, A.par]]]) {
  const r = await launch(pairs, buy)
  check(label, r.ok && !!r.token && r.got >= r.min && r.min > 0n, `simulated ${fmt(r.tokensOut)}, min ${fmt(r.min)}, received ${fmt(r.got ?? 0n)}, TokenLaunched ${r.token ? "found" : "missing"}`)
}
const r = await launch([zeroAddress], buy, -10_000n) // min = twice the simulation
check("form launch with an unreachable minimum reverts", !r.ok)
console.log(fails ? `launch form: ${fails} failed` : "launch form: all passed")
process.exit(fails ? 1 : 0)
