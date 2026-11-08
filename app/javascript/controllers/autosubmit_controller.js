import { Controller } from "@hotwired/stimulus"
export default class extends Controller {
  submit() { clearTimeout(this.t); this.t = setTimeout(() => this.element.requestSubmit(), 300) }
}
