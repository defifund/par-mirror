// Browser wallet (EIP-1193) + viem clients. Signing only ever happens in the user's wallet.
import { createPublicClient, createWalletClient, custom, http } from "viem"
import { getChain } from "par-sdk"

const eth = () => window.ethereum
const state = { address: null, chainId: null }
const listeners = new Set()
const emit = () => listeners.forEach((l) => l({ ...state }))

export function onWallet(fn) { listeners.add(fn); fn({ ...state }); return () => listeners.delete(fn) }
export const walletState = () => ({ ...state })

if (eth()) {
  eth().request({ method: "eth_accounts" }).then((a) => { state.address = a[0]?.toLowerCase() ?? null; emit() }).catch(() => {})
  eth().request({ method: "eth_chainId" }).then((c) => { state.chainId = Number(c); emit() }).catch(() => {})
  eth().on?.("accountsChanged", (a) => { state.address = a[0]?.toLowerCase() ?? null; emit() })
  eth().on?.("chainChanged", (c) => { state.chainId = Number(c); emit() })
}

export async function connect() {
  if (!eth()) throw new Error("No browser wallet found. Install MetaMask, Rabby or another EIP-1193 wallet.")
  const a = await eth().request({ method: "eth_requestAccounts" })
  state.address = a[0]?.toLowerCase() ?? null
  state.chainId = Number(await eth().request({ method: "eth_chainId" }))
  emit()
  return state.address
}

export function viemChain(ci) {
  const base = getChain(ci.id)
  return { ...base, rpcUrls: { default: { http: [ci.rpc] } } }
}

const clients = new Map()
export function publicClient(ci) {
  if (!clients.has(ci.id)) clients.set(ci.id, createPublicClient({ chain: viemChain(ci), transport: http(ci.rpc), batch: { multicall: true } }))
  return clients.get(ci.id)
}

export async function ensureChain(ci) {
  if (state.chainId === ci.id) return
  const hex = "0x" + ci.id.toString(16)
  try {
    await eth().request({ method: "wallet_switchEthereumChain", params: [{ chainId: hex }] })
  } catch (e) {
    if (e?.code !== 4902 && !/unrecognized|not added|unknown chain/i.test(e?.message ?? "")) throw e
    const c = getChain(ci.id)
    await eth().request({ method: "wallet_addEthereumChain", params: [{ chainId: hex, chainName: c.name, nativeCurrency: c.nativeCurrency, rpcUrls: [ci.rpc], blockExplorerUrls: [ci.explorer] }] })
  }
  state.chainId = ci.id
  emit()
}

// Simulate, send through the wallet, wait for the receipt.
export async function sendTx(ci, tx) {
  if (!state.address) await connect()
  await ensureChain(ci)
  const pc = publicClient(ci)
  await pc.call({ account: state.address, to: tx.to, data: tx.data, value: tx.value })
  const wc = createWalletClient({ chain: viemChain(ci), transport: custom(eth()), account: state.address })
  const hash = await wc.sendTransaction({ account: state.address, chain: viemChain(ci), to: tx.to, data: tx.data, value: tx.value })
  const receipt = await pc.waitForTransactionReceipt({ hash })
  if (receipt.status !== "success") throw new Error(`transaction reverted: ${hash}`)
  return receipt
}

export const errMsg = (e) => (e?.shortMessage || e?.details || e?.message || String(e)).split("\n")[0].slice(0, 300)

export function compact(n, digits = 2) {
  if (n == null || !isFinite(n)) return "—"
  const a = Math.abs(n)
  if (a >= 1e9) return (n / 1e9).toFixed(digits) + "B"
  if (a >= 1e6) return (n / 1e6).toFixed(digits) + "M"
  if (a >= 1e3) return (n / 1e3).toFixed(digits) + "K"
  if (a === 0) return "0"
  if (a < 0.0001) return n.toExponential(2)
  return n.toLocaleString(undefined, { maximumSignificantDigits: 4 })
}
export function price(n) {
  if (n == null || !isFinite(n) || n === 0) return "—"
  if (n >= 1) return n.toLocaleString(undefined, { maximumFractionDigits: 4 })
  const m = n.toFixed(20).match(/^0\.(0*)(\d{1,4})/)
  if (!m) return n.toPrecision(4)
  return m[1].length >= 4 ? `0.0(${m[1].length})${m[2]}` : `0.${m[1]}${m[2]}`
}
export const short = (a) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "—")
export const units = (raw, dec = 18) => (raw == null ? 0 : Number(BigInt(raw)) / 10 ** dec)

// personal_sign (EIP-191) of a UTF-8 text, as Sign-In with Ethereum expects; no transaction, no gas
export async function signMessage(address, text) {
  const hex = "0x" + Array.from(new TextEncoder().encode(text), (b) => b.toString(16).padStart(2, "0")).join("")
  return eth().request({ method: "personal_sign", params: [hex, address] })
}

export function showMsg(el, ok, text) {
  el.hidden = false
  el.className = `msg ${ok ? "ok" : "err"}`
  el.textContent = text
}
