import { Controller } from "@hotwired/stimulus"
import { t } from "../par/i18n"
import { connect as connectWallet, walletState, signMessage, errMsg, showMsg } from "../par/wallet"

// "Sign in with your wallet": the server writes an EIP-4361 message, the wallet signs it (free, no
// transaction), the server checks the signature and remembers the address for a week.
export default class extends Controller {
  static targets = ["msg", "button"]

  async signIn() {
    try {
      this.busy(true)
      const address = walletState().address || (await connectWallet())
      if (!address) throw new Error(t("wallet.connect_first"))
      const { message, error } = await this.post("/api/auth/message", { address, chainId: walletState().chainId })
      if (error) throw new Error(error)
      this.say(true, t("signin.check_wallet"))
      const signature = await signMessage(address, message)
      const res = await this.post("/api/auth/verify", { signature })
      if (res.error) throw new Error(res.error)
      window.Turbo.visit(location.href, { action: "replace" })
    } catch (e) {
      this.say(false, errMsg(e))
      this.busy(false)
    }
  }

  async signOut() {
    await fetch("/api/auth", { method: "DELETE", headers: { "x-csrf-token": csrf() } })
    window.Turbo.visit(location.href, { action: "replace" })
  }

  async post(url, body) {
    const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json", accept: "application/json", "x-csrf-token": csrf() }, body: JSON.stringify(body) })
    return r.json().catch(() => ({ error: `HTTP ${r.status}` }))
  }

  say(ok, text) { if (this.hasMsgTarget) showMsg(this.msgTarget, ok, text) }
  busy(on) { if (this.hasButtonTarget) this.buttonTarget.disabled = on }
}

const csrf = () => document.querySelector("meta[name=csrf-token]")?.content || ""
