module Par
  # /distributions, /rewards, /floor and the floor[] field of launch rows (par-sdk INTEGRATION.md A8/A9).
  class Payouts
    def initialize(chain)
      @chain = chain
      @pricing = Pricing.new(chain)
    end

    # { asset, symbol, decimals } for ETH (zero address), the launch token itself or a quote token
    def asset_meta(asset)
      @asset_meta ||= {}
      @asset_meta[asset] ||= begin
        if asset == Chains::ZERO
          { asset:, symbol: @chain.reference[:native] ? @chain.reference[:symbol] : "native", decimals: 18 }
        elsif (l = Launch.where(chain_id: @chain.id, token: asset).pick(:symbol, :decimals))
          { asset:, symbol: l[0], decimals: l[1] || 18 }
        elsif (q = QuoteAsset.where(chain_id: @chain.id, pair_token: asset).pick(:symbol, :decimals))
          { asset:, symbol: q[0], decimals: q[1] }
        else
          { asset:, symbol: "?", decimals: 18 }
        end
      end
    end

    def distributions(token, limit: 200)
      token = token.downcase
      scope = Distribution.where(chain_id: @chain.id, token:)
      sums = scope.group(:asset).sum(:total)
      {
        token:, vault: @chain.addr(:holder_vault), wallet: @chain.addresses[:holders_wallet]&.downcase,
        rounds: scope.distinct.count(:round), lastAt: scope.maximum(:ts),
        total: sums[token].to_i.to_s,
        totals: sums.map { |asset, t| asset_meta(asset).merge(total: t.to_i.to_s) },
        items: scope.order(block_number: :desc, log_index: :desc).limit(limit.clamp(1, 1000)).map do |d|
          asset_meta(d.asset).merge(id: "#{d.tx_hash}-#{d.log_index}", round: d.round, total: d.total.to_i.to_s,
                                    recipients: d.recipients, txHash: d.tx_hash, timestamp: d.ts)
        end
      }
    end

    def rewards(owner, token: nil, limit: 500)
      owner = owner.downcase
      scope = Reward.where(chain_id: @chain.id, owner:)
      scope = scope.where(token: token.downcase) if token.present?
      sums = scope.group(:asset).sum(:amount)
      {
        owner:,
        total: token.present? ? sums[token.downcase].to_i.to_s : nil,
        totals: sums.any? ? sums.map { |asset, t| asset_meta(asset).merge(total: t.to_i.to_s) } : nil,
        items: scope.order(block_number: :desc, log_index: :desc).limit(limit.clamp(1, 2000)).map do |r|
          { id: "#{r.tx_hash}-#{r.log_index}", token: r.token, asset: r.asset, amount: r.amount.to_i.to_s, txHash: r.tx_hash, timestamp: r.ts }
        end
      }
    end

    # Current wall per quote for every floor launch: { token => [wall, ...] }
    def floor_by_token
      latest = FloorWall.where(chain_id: @chain.id).select("DISTINCT ON (token, quote) *").order(:token, :quote, block_number: :desc, log_index: :desc)
      latest.group_by(&:token).transform_values { |ws| ws.map { wall_row(_1) } }
    end

    def floor(row, quote: nil)
      token = row[:token]
      walls = floor_by_token[token] || []
      history = if quote.present?
                  FloorWall.where(chain_id: @chain.id, token:, quote: quote.downcase).order(:block_number, :log_index).map { wall_row(_1) }
                end
      vault = @chain.addr(:floor_vault)
      { token:, vault: row[:feeMode] == "floor" ? vault : nil, feeMode: row[:feeMode], walls:,
        feeBurnedToken: Burn.where(chain_id: @chain.id, token:, from_addr: vault).sum(:amount).to_i.to_s, history: }
    end

    # Price at the wall's edge nearest the market, raw quote units per whole token.
    # token = currency0: price(1 per 0) = quote/token, the quote-only wall sits below -> tickUpper.
    # token = currency1: price = token/quote, the wall sits above -> invert at tickLower.
    def wall_row(w)
      m = market_for(w.token, w.quote)
      standing = w.liquidity.to_i.positive? && w.quote_in_wall.to_i.positive?
      price_q = nil
      price_eth = nil
      cap_eth = nil
      if m && standing
        tok_dec = m[:token_decimals]
        raw = m[:c0] ? 1.0001**w.tick_upper : 1.0001**-w.tick_lower # raw quote units per raw token unit
        price_q = raw * 10**tok_dec
        price_eth = price_q / 10**m[:qdec] * @pricing.quote_eth(w.quote)
        cap_eth = price_eth * w.circulating.to_f / 10**tok_dec
      end
      { quote: w.quote, standing:, tickLower: w.tick_lower, tickUpper: w.tick_upper, liquidity: w.liquidity.to_i.to_s,
        quoteInWall: w.quote_in_wall.to_i.to_s, circulating: w.circulating.to_i.to_s,
        floorPriceQuote: price_q&.then { format("%.6f", _1).sub(/\.?0+\z/, "") }, floorPriceEth: price_eth, floorMarketCapEth: cap_eth,
        txHash: w.tx_hash, timestamp: w.ts }
    end

    private

    def market_for(token, quote)
      @markets ||= {}
      @markets[[token, quote]] ||= begin
        r = Market.where(chain_id: @chain.id, token:, pair_token: quote).pick(:token_is_c0, :quote_decimals)
        r && { c0: r[0], qdec: r[1], token_decimals: Launch.where(chain_id: @chain.id, token:).pick(:decimals) || 18 }
      end
    end
  end
end
