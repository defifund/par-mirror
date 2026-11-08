require "net/http"

module Par
  # Tokenized stocks a launch can pair with, per chain — the "Stocks" quick pick of the original create page:
  #   Robinhood Chain: Robinhood's own stock tokens   (list via stocksonchain.io, CC BY 4.0)
  #   Base:            Coinbase and Dinari tokens     (stocksonchain.io)
  #   BNB Chain:       Ondo and xStocks tokens        (stocksonchain.io)
  #   Arc:             stocks bridged by long.supply  (longstocks.io)
  # Every address is checked against the chain's on-chain quote pricer: greyed ones cannot be a quote yet.
  module Stocks
    SOC_URL = "https://stocksonchain.io/api/tokens.json".freeze
    LONG_URL = "https://longstocks.io/api/pairs".freeze
    SOURCES = {
      4663 => { kind: "issuers", soc_chain: "robinhood-chain", issuers: [{ id: "robinhood", name: "Robinhood", url: "https://robinhood.com" }] },
      8453 => { kind: "issuers", soc_chain: "base", issuers: [{ id: "coinbase", name: "Coinbase", url: "https://www.coinbase.com/tokenize" },
                                                             { id: "dinari", name: "Dinari", url: "https://dinari.com" }] },
      56 => { kind: "issuers", soc_chain: "bnb-chain", issuers: [{ id: "ondo", name: "Ondo Global Markets", url: "https://ondo.finance" },
                                                                { id: "backed-xstocks", name: "xStocks", url: "https://xstocks.fi" }] },
      5042 => { kind: "bridged", issuer: "long.supply", issuerUrl: "https://longstocks.io", custodial: true }
    }.freeze

    module_function

    def for(chain)
      src = SOURCES[chain.id] or return nil
      Rails.cache.fetch(["par/stocks", chain.id], expires_in: 6.hours, race_condition_ttl: 1.minute) do
        items = src[:kind] == "bridged" ? longstocks : stocksonchain(src[:soc_chain], src[:issuers].map { _1[:id] })
        items = with_priceability(chain, items)
        attribution = src[:kind] == "bridged" ? { name: "longstocks.io", url: "https://longstocks.io" } : { name: "stocksonchain.io", url: "https://stocksonchain.io", license: "CC BY 4.0" }
        src.except(:soc_chain).merge(attribution:, items: items.sort_by { [_1[:priceable] ? 0 : 1, _1[:symbol]] }, at: Time.now.to_i)
      end
    rescue StandardError => e
      Rails.logger.warn("[par stocks #{chain.id}] #{e.class}: #{e.message}")
      nil
    end

    def stocksonchain(soc_chain, issuers)
      JSON.parse(get(SOC_URL))["stocks"].flat_map do |s|
        s["listings"].select { _1["chain"] == soc_chain && issuers.include?(_1["issuer"]) && !paused?(_1["paused"]) }.map do |l|
          { address: l["address"].downcase, symbol: l["onchainSymbol"].presence || s["ticker"], name: s["company"],
            decimals: l["decimals"] || 18, issuer: l["issuer"], logoUrl: nil }
        end
      end.uniq { _1[:address] }
    end

    def paused?(v) = v.is_a?(Hash) ? v.values.any? : v.present?

    def longstocks
      JSON.parse(get(LONG_URL))["pairs"].filter_map do |p|
        next unless p["arcStock"]
        { address: p["arcStock"].downcase, symbol: p["symbol"], name: p["company"] || p["name"], decimals: p["decimals"] || 18,
          issuer: "long.supply", logoUrl: p["logoURI"] || p["image"] }
      end
    end

    # the pricer decides what can be a quote (deep enough route to the reference asset)
    def with_priceability(chain, items)
      return items if items.empty?
      rpc = Rpc.new(chain)
      ok = items.each_slice(150).flat_map do |slice|
        rpc.multi_read(slice.map { [chain.addr(:quote_pricer), "isPriceable(address)", [_1[:address]], ["bool"]] })
      end
      items.zip(ok).map { |it, r| it.merge(priceable: r&.first == true) }
    end

    def get(url)
      uri = URI(url)
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |h|
        h.get(uri.request_uri, "user-agent" => "par-community-mirror", "accept" => "application/json")
      end
      raise "#{url}: HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)
      res.body
    end
  end
end
