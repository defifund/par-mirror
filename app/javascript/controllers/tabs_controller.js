import { Controller } from "@hotwired/stimulus"
export default class extends Controller {
  static targets = ["panel"]
  show(e) {
    const tab = e.currentTarget.dataset.tab
    e.currentTarget.parentElement.querySelectorAll("button").forEach((b) => b.classList.toggle("active", b === e.currentTarget))
    this.panelTargets.forEach((p) => { p.hidden = p.dataset.tab !== tab })
  }
}
