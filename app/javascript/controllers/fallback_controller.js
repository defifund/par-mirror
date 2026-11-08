import { Controller } from "@hotwired/stimulus"
// Replace a broken token image (dead IPFS gateway, etc.) with its initials.
export default class extends Controller {
  static values = { text: String }
  connect() {
    const swap = () => {
      const d = document.createElement("div")
      d.className = "logo ph"
      d.style.width = d.style.height = `${this.element.width}px`
      d.textContent = this.textValue
      this.element.replaceWith(d)
    }
    if (this.element.complete && this.element.naturalWidth === 0) swap()
    else this.element.addEventListener("error", swap, { once: true })
  }
}
