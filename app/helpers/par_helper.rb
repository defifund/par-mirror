module ParHelper
  def compact(n, digits = 2)
    return "—" if n.nil? || (n.respond_to?(:finite?) && !n.finite?)
    n = n.to_f
    a = n.abs
    return "0" if a.zero?
    return format("%.#{digits}fB", n / 1e9) if a >= 1e9
    return format("%.#{digits}fM", n / 1e6) if a >= 1e6
    return format("%.#{digits}fK", n / 1e3) if a >= 1e3
    return format("%.2e", n) if a < 0.0001
    n.round(4 - Math.log10(a).floor - 1).to_s.sub(/\.0\z/, "")
  end

  def usd(n) = n.nil? || n.to_f.zero? ? "—" : "$#{compact(n)}"

  # small prices with a zero-count subscript, e.g. 0.0<sub>6</sub>4213
  def price(n)
    return "—" if n.nil? || n.to_f.zero?
    n = n.to_f
    return number_with_precision(n, precision: 4, delimiter: ",", strip_insignificant_zeros: true) if n >= 1
    s = format("%.20f", n)
    m = s.match(/\A0\.(0*)(\d{1,4})/)
    return format("%.4g", n) unless m
    m[1].length >= 4 ? safe_join(["0.0", tag.sub(m[1].length), m[2]]) : "0.#{m[1]}#{m[2]}"
  end

  def short(a) = a.present? ? "#{a[0, 6]}…#{a[-4..]}" : "—"
  def units(raw, dec = 18) = raw.to_i.fdiv(10**dec.to_i)

  def ago(ts)
    return "—" if ts.blank?
    s = Time.now.to_i - ts.to_i
    return t("time.s", n: s) if s < 60
    return t("time.m", n: s / 60) if s < 3600
    return t("time.h", n: s / 3600) if s < 86_400
    t("time.d", n: s / 86_400)
  end

  # an address as a link to the explorer, labelled with its wallet-signed profile name when it has one
  def who(chain, addr)
    return "—" if addr.blank?
    name = Profile.names[addr.downcase]
    return explorer(chain, "address", addr) unless name
    link_to(name.truncate(20), "#{chain.explorer}/address/#{addr}", target: "_blank", rel: "noopener", class: "named", title: "#{name} · #{addr}")
  end

  def explorer(chain, kind, id, label = nil) = link_to(label || short(id), "#{chain.explorer}/#{kind}/#{id}", target: "_blank", rel: "noopener")

  def fee_mode_tag(mode) = (tag.span(t("fee_mode_tag.#{mode}"), class: "tag") if %w[holders burn floor].include?(mode))

  def token_logo(row, size: 36)
    if row[:logoUrl]
      image_tag(row[:logoUrl], class: "logo", width: size, height: size, loading: "lazy", alt: "",
                data: { controller: "fallback", fallback_text_value: row[:symbol].to_s[0, 2] })
    else
      tag.div(row[:symbol].to_s[0, 2], class: "logo ph", style: "width:#{size}px;height:#{size}px")
    end
  end

  CHAIN_SHORT = { "rh" => "RH", "arc" => "ARC", "base" => "BASE", "bnb" => "BNB" }.freeze
  def chain_badge(slug) = tag.span(CHAIN_SHORT[slug] || slug.to_s.upcase, class: "chain-badge chain-#{slug}")

  def safe_url(u) = u.to_s.match?(%r{\Ahttps?://}) ? u : nil

  # Plain-text summary of the stats page for "Copy as text"
  def stats_text(s, d, leaders, chain_tab)
    days = d[:days]
    span = d[:range] == "all" ? t("stats.all_time") : t("stats.last_days", n: d[:range].delete("d"))
    scope = chain_tab == "all" ? t("common.all_chains") : Par::Chains.get(chain_tab).name
    u = s[:refUsd]
    dates = "#{l(Time.at(d[:from]).utc.to_date, format: :md)} – #{l(Time.at(d[:to]).utc.to_date, format: :mdy)}"
    lines = [t("stats.text.head", area: scope, span:, dates:),
             t("stats.text.volume", window: usd(days.sum { _1[:volumeUsd] }), all: usd(s[:volumeEth] * u)),
             t("stats.text.fees", creators: usd(days.sum { _1[:creatorFeesUsd] }), protocol: usd(days.sum { _1[:protocolFeesUsd] })),
             t("stats.text.trades", trades: number_with_delimiter(days.sum { _1[:trades] }), new: days.sum { _1[:launches] }, total: s[:launches]),
             t("stats.text.holders", holders: number_with_delimiter(s[:holderWallets]), traders: number_with_delimiter(s[:traderWallets])),
             t("stats.text.payouts", window: usd(days.sum { _1[:payoutsUsd] }), all: usd(s[:payoutsEth] * u))]
    lines << t("stats.text.par_burned", v: compact(units(s[:par][:burned]))) if s[:par]
    %i[volume fees payouts].each do |k|
      next if leaders[k].empty?
      lines << t("stats.text.top_#{k}") + leaders[k].first(5).map { "$#{_1[:symbol]} #{usd(_1[:valueUsd])}" }.join(", ")
    end
    lines.join("\n")
  end
end
