import { Controller } from "@hotwired/stimulus"
import { t } from "../par/i18n"
export default class extends Controller {
  static values = { text: String }
  copy() {
    navigator.clipboard?.writeText(this.textValue)
    this.element.dataset.copiedLabel = t("common.copied")
    this.element.classList.add("copied")
    setTimeout(() => this.element.classList.remove("copied"), 1200)
  }
}
