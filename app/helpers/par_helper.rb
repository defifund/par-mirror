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
    return "#{s}s" if s < 60
    return "#{s / 60}m" if s < 3600
    return "#{s / 3600}h" if s < 86_400
    "#{s / 86_400}d"
  end

  def explorer(chain, kind, id, label = nil) = link_to(label || short(id), "#{chain.explorer}/#{kind}/#{id}", target: "_blank", rel: "noopener")

  FEE_MODE_LABEL = { "holders" => "fees → holders", "burn" => "buyback & burn", "floor" => "floor" }.freeze
  def fee_mode_tag(mode) = FEE_MODE_LABEL[mode] && tag.span(FEE_MODE_LABEL[mode], class: "tag")

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
    span = d[:range] == "all" ? "all time" : "last #{d[:range].delete('d')} days"
    scope = chain_tab == "all" ? "all chains" : Par::Chains.get(chain_tab).name
    u = s[:refUsd]
    lines = ["par stats (#{scope}, #{span}, #{Time.at(d[:from]).utc.strftime('%b %-d')} – #{Time.at(d[:to]).utc.strftime('%b %-d, %Y')})",
             "Volume: #{usd(days.sum { _1[:volumeUsd] })} in the window, #{usd(s[:volumeEth] * u)} all time",
             "Fees: #{usd(days.sum { _1[:creatorFeesUsd] })} to creators & holders, #{usd(days.sum { _1[:protocolFeesUsd] })} to the protocol",
             "Trades: #{number_with_delimiter(days.sum { _1[:trades] })} · new tokens: #{days.sum { _1[:launches] }} · tokens in total: #{s[:launches]}",
             "Holders: #{number_with_delimiter(s[:holderWallets])} wallets hold a par token; #{number_with_delimiter(s[:traderWallets])} ever traded",
             "Holder payouts: #{usd(days.sum { _1[:payoutsUsd] })} in the window, #{usd(s[:payoutsEth] * u)} all time"]
    lines << "$par burned: #{compact(units(s[:par][:burned]))}" if s[:par]
    { volume: "Top by volume", fees: "Top by fees", payouts: "Top by holder payouts" }.each do |k, t|
      next if leaders[k].empty?
      lines << "#{t}: " + leaders[k].first(5).map { "$#{_1[:symbol]} #{usd(_1[:valueUsd])}" }.join(", ")
    end
    lines.join("\n")
  end
end
