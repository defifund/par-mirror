module Par
  # "Any token" search on the create page: by name, ticker or address, among assets a launch can pair with.
  # Candidates: assets par launches already use as quotes, the verified quote list, par tokens themselves
  # and the chain's stock tokens. The browser still asks the on-chain pricer before adding one.
  module TokenSearch
    module_function

    KIND_ORDER = { "quote" => 0, "verified" => 0, "stock" => 1, "par" => 2 }.freeze

    def search(chain, q, limit: 12)
      q = q.to_s.strip.downcase
      return [] if q.size < 2
      if q.match?(/\A0x\h{40}\z/)
        hit = candidates(chain).find { _1[:address] == q }
        return [hit || { address: q, symbol: nil, name: "Address", kind: "address" }]
      end
      scored = candidates(chain).filter_map do |c|
        sym, name = c[:symbol].to_s.downcase, c[:name].to_s.downcase
        rank = if sym == q then 0 elsif sym.start_with?(q) then 1 elsif name.start_with?(q) then 2
               elsif sym.include?(q) || name.include?(q) then 3 end
        [rank, KIND_ORDER[c[:kind]], -c[:weight].to_f, c] if rank
      end
      scored.sort_by { _1[0, 3] }.map(&:last).uniq { _1[:address] }.first(limit).map { _1.except(:weight) }
    end

    def candidates(chain)
      Rails.cache.fetch(["par/token-search", chain.id], expires_in: 10.minutes) do
        rows = LaunchRows.for(chain)
        used = Market.where(chain_id: chain.id).group(:pair_token).count
        quotes = QuoteAsset.where(chain_id: chain.id).map do |a|
          { address: a.pair_token, symbol: a.symbol, name: a.symbol, decimals: a.decimals, kind: "quote", weight: 1000 + used[a.pair_token].to_i }
        end
        verified = LaunchRows.verified(chain.id).map { { address: _1, symbol: nil, name: nil, decimals: nil, kind: "verified", weight: 500 } }
        verified.each { |v| v.merge!(quotes.find { _1[:address] == v[:address] }&.slice(:symbol, :name, :decimals) || {}) }
        # par tokens with a real following only, one per ticker (copycats share names)
        par = rows.select { _1[:holders].to_i >= 5 }.sort_by { -_1[:marketCapEth].to_f }.uniq { _1[:symbol].to_s.downcase }
                  .map { { address: _1[:token], symbol: _1[:symbol], name: _1[:name], decimals: _1[:decimals], kind: "par", weight: _1[:marketCapEth].to_f } }
        stocks = (Stocks.for(chain)&.dig(:items) || []).map { _1.slice(:address, :symbol, :name, :decimals).merge(kind: "stock", weight: _1[:priceable] ? 100 : 0) }
        stock_addrs = stocks.to_h { [_1[:address], _1] }
        # spam symbols (hundreds of tickers glued together) would match every query
        all = (quotes + verified.select { _1[:symbol] } + stocks + par).select { _1[:symbol].to_s.size.between?(1, 24) }
        # a stock that is already used as a quote is still a stock
        all.map { |c| (st = stock_addrs[c[:address]]) && c[:kind] != "stock" ? c.merge(kind: "stock", name: st[:name]) : c }
      end
    end
  end
end
