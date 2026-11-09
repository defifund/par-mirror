// Translations for the Stimulus controllers: the layout renders the current locale's `js.*` keys into
// <script type="application/json" id="i18n-js">; t("trade.buy", { symbol: "PAR" }) uses Rails-style %{name}.
let src = null, dict = {}

export function t(key, vars = {}) {
  const el = document.getElementById("i18n-js")
  if (el !== src) { src = el; try { dict = el ? JSON.parse(el.textContent) : {} } catch { dict = {} } }
  let s = key.split(".").reduce((o, k) => (o && typeof o === "object" ? o[k] : undefined), dict)
  if (typeof s !== "string") s = key
  return s.replace(/%\{(\w+)\}/g, (_, k) => (vars[k] ?? ""))
}
