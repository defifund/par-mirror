module Par
  # Read models behind the API and the pages.
  class Queries
    def initialize(chain)
      @chain = chain
    end

    def rows = LaunchRows.for(@chain)
    def system = Indexer.new(@chain).system_addresses

    # fill: :inline resolves missing traders before answering (API), :later enqueues it (pages)
    def trades(token: nil, wallet: nil, limit: 200, fill: :inline)
      limit = (limit.presence || 200).to_i.clamp(1, 500)
      scope = Trade.where(chain_id: @chain.id)
      scope = scope.where(token: token.downcase) if token.present?
      scope = scope.where(trader: wallet.downcase) if wallet.present?
      list = scope.order(block_number: :desc, log_index: :desc).limit(limit).to_a
      missing = list.select { _1.trader.nil? }.map(&:tx_hash).uniq.first(200)
      if missing.any? && fill == :later
        FillTradersJob.perform_later(@chain.id, missing)
      elsif missing.any?
        Indexer.new(@chain).fill_traders(hashes: missing)
        list = scope.order(block_number: :desc, log_index: :desc).limit(limit).to_a
      end
      markets = Market.where(chain_id: @chain.id, pool_id: list.map(&:pool_id).uniq).index_by(&:pool_id)
      kinds = Launch.where(chain_id: @chain.id, token: list.map(&:token).uniq).pluck(:token, :kind, :symbol).to_h { [_1, [_2, _3]] }
      list.map do |t|
        m = markets[t.pool_id]
        kind, symbol = kinds[t.token]
        { txHash: t.tx_hash, token: t.token, symbol:, trader: t.trader, sender: t.sender, isBuy: t.is_buy,
          quoteAmount: t.quote_amount.to_i.to_s, tokenAmount: t.token_amount.to_i.to_s, fee: t.fee, priceQuoteX18: t.price_x18.to_i.to_s,
          priceEth: t.price_eth, valueEth: t.value_eth, timestamp: t.ts, blockNumber: t.block_number, logIndex: t.log_index,
          market: kind == "multi" ? t.market : nil, pairToken: m&.pair_token, quoteSymbol: m&.quote_symbol, quoteDecimals: m&.quote_decimals }
      end
    end

    # OHLC in quote units per whole token (open..close) and in the reference asset (*Eth), from the trade tape
    def candles(token, step:, limit:, before: nil, market: nil)
      before ||= (Trade.where(chain_id: @chain.id, token:).maximum(:ts) || Time.now.to_i) + step
      scope = Trade.where(chain_id: @chain.id, token:).where(ts: (before - step * limit)...before)
      scope = scope.where(market:) if market
      out = []
      cur = nil
      dec = Market.where(chain_id: @chain.id, token:).pluck(:pool_id, :quote_decimals).to_h
      scope.order(:block_number, :log_index).pluck(:ts, :price_x18, :price_eth, :quote_amount, :pool_id).each do |ts, px, pe, qa, pid|
        bucket = ts - ts % step
        px = px.to_f
        if cur.nil? || cur[:time] != bucket
          prev = cur
          out << cur if cur
          o, oe = prev ? [prev[:close], prev[:closeEth]] : [px, pe]
          cur = { time: bucket, open: o, high: [o, px].max, low: [o, px].min, close: px, openEth: oe, highEth: [oe, pe].max, lowEth: [oe, pe].min, closeEth: pe, volumeQuote: 0.0, trades: 0 }
        end
        cur[:high] = [cur[:high], px].max
        cur[:low] = [cur[:low], px].min
        cur[:close] = px
        cur[:highEth] = [cur[:highEth], pe].max
        cur[:lowEth] = [cur[:lowEth], pe].min
        cur[:closeEth] = pe
        cur[:volumeQuote] += qa.to_f / 10**dec.fetch(pid, 18)
        cur[:trades] += 1
      end
      out << cur if cur
      out.last(limit)
    end

    def holders(token, limit: 100)
      l = Launch.find_by(chain_id: @chain.id, token:)
      scope = Balance.where(chain_id: @chain.id, token:).where("balance > 0").where.not(owner: system)
      circ = l ? l.circulating.to_f : 0
      in_pools = Balance.where(chain_id: @chain.id, token:, owner: @chain.addr(:pool_manager)).pick(:balance).to_i
      { token:, holders: scope.count, inPools: in_pools.to_s,
        items: scope.order(balance: :desc).limit(limit).pluck(:owner, :balance).map { |o, b| { owner: o, balance: b.to_i.to_s, share: circ.positive? ? b.to_f / circ : 0 } } }
    end

    def positions(owner)
      by_token = rows.index_by { _1[:token] }
      bals = Balance.where(chain_id: @chain.id, owner:).where("balance > 0").pluck(:token, :balance)
      flows = Trade.where(chain_id: @chain.id, trader: owner).group(:token, :is_buy).sum(:value_eth)
      items = bals.filter_map do |tok, bal|
        r = by_token[tok] or next
        amt = bal.to_f / 1e18
        { token: tok, balance: bal.to_i.to_s, valueEth: amt * r[:lastPriceEth], valueUsd: amt * r[:lastPriceUsd],
          costEth: flows[[tok, true]].to_f, proceedsEth: flows[[tok, false]].to_f, launch: r }
      end.sort_by { -_1[:valueEth] }
      launched = rows.select { _1[:deployer] == owner || _1[:creatorFeeRecipient] == owner }.sort_by { -_1[:createdBlock] }
      { owner:, positions: items, launched: }
    end

    def fees(row)
      rpc = Rpc.new(@chain)
      pending =
        if row[:kind] == "single"
          a0, a1 = rpc.call(@chain.addr(:locker), "pendingFees(address)", row[:token], returns: %w[uint256 uint256])
          [{ market: 0, amount0: a0.to_s, amount1: a1.to_s }]
        else
          a0, a1 = rpc.call(@chain.addr(:multi_locker), "pendingFeesAll(address)", row[:token], returns: %w[uint256[] uint256[]])
          a0.each_with_index.map { |x, i| { market: i, amount0: x.to_s, amount1: a1[i].to_s } }
        end
      collected = FeeCollection.where(chain_id: @chain.id, token: row[:token]).order(block_number: :desc).limit(200)
                               .map { _1.attributes.except("id", "chain_id").to_h { |k, v| [k.camelize(:lower), %w[protocol0 protocol1 creator0 creator1].include?(k) ? v.to_i.to_s : v] } }
      { token: row[:token], feeMode: row[:feeMode], creatorFeeRecipient: row[:creatorFeeRecipient], pending:, collected: }
    end

    # creator fee balances waiting in the escrow for `owner`
    def claimable(owner)
      rpc = Rpc.new(@chain)
      esc = @chain.addr(:fee_escrow)
      mine = rows.select { _1[:creatorFeeRecipient] == owner }
      assets = mine.flat_map { |r| [r[:token]] + (r[:markets] || [r]).map { _1[:pairToken] } }.uniq - [Chains::ZERO]
      native = rpc.call(esc, "balanceOf(address)", owner, returns: ["uint256"]).first
      tokens = rpc.pmap(assets, threads: 6) { |a| [a, rpc.call(esc, "balanceOfToken(address,address)", owner, a, returns: ["uint256"]).first] }
      symbols = rows.to_h { [_1[:token], _1[:symbol]] }.merge(QuoteAsset.where(chain_id: @chain.id).pluck(:pair_token, :symbol).to_h)
      decimals = QuoteAsset.where(chain_id: @chain.id).pluck(:pair_token, :decimals).to_h
      { owner:, escrow: esc, native: native.to_s,
        tokens: tokens.reject { _2.zero? }.map { |a, v| { asset: a, symbol: symbols[a], decimals: decimals[a] || 18, amount: v.to_s } } }
    end

    def buybacks
      par, wallet = @chain.addr(:par), @chain.addr(:buyback_wallet)
      items = Burn.where(chain_id: @chain.id, token: par, from_addr: wallet).order(block_number: :desc)
      # the wallet buys $par in separate transactions (tokens land in the wallet), then burns them
      buys = Trade.where(chain_id: @chain.id, token: par, is_buy: true, trader: wallet)
      spent = buys.sum(:value_eth)
      { wallet:, token: par, burnedTotal: Launch.where(chain_id: @chain.id, token: par).pick(:burned).to_i.to_s,
        burned: items.sum(:amount).to_i.to_s, ethSpent: spent, buys: buys.count, count: items.count,
        items: items.limit(500).map { { id: "#{_1.tx_hash}-#{_1.log_index}", amount: _1.amount.to_i.to_s, txHash: _1.tx_hash, timestamp: _1.ts } } }
    end

    RANGES = { "7d" => 7, "30d" => 30, "90d" => 90, "all" => nil }.freeze

    # Daily series for the stats charts. The window ends at the last indexed day (today once the
    # history is replayed), so a partially synced index still shows its most recent month.
    def daily(range, end_day: nil, start_day: nil)
      days = RANGES.fetch(range) { 30 }
      last_ts = Trade.where(chain_id: @chain.id).maximum(:ts) || Time.now.to_i
      end_day ||= last_ts - last_ts % 86_400
      start_day ||= days ? end_day - (days - 1) * 86_400 : (Launch.where(chain_id: @chain.id).minimum(:launched_at) || end_day).then { _1 - _1 % 86_400 }
      day = Arel.sql("(t.ts / 86400) * 86400")
      trades = Trade.from("trades t").where("t.chain_id = ? AND t.ts >= ? AND t.ts < ?", @chain.id, start_day, end_day + 86_400)
      tday = trades.group(day).pluck(day, Arel.sql("COUNT(*)"), Arel.sql("SUM(t.value_eth)"), Arel.sql("COUNT(DISTINCT t.trader)")).to_h { |d, *v| [d, v] }
      # fee a trade paid = its value × the pool fee; the protocol takes protocolFeeShare of the base fee, the creator the rest
      fees = trades.joins("JOIN launches l ON l.chain_id = t.chain_id AND l.token = t.token").group(day)
                   .pluck(day, Arel.sql("SUM(t.value_eth * l.pool_fee / 1e6)"), Arel.sql("SUM(t.value_eth * l.base_fee_bps / 1e4 * l.protocol_fee_share_bps / 1e4)"))
                   .to_h { |d, total, proto| [d, [total.to_f - proto.to_f, proto.to_f]] }
      lday = Arel.sql("(launched_at / 86400) * 86400")
      launches = Launch.where(chain_id: @chain.id).where(launched_at: start_day...(end_day + 86_400)).group(lday).count
      buybacks = if @chain.addr(:par) != Chains::ZERO
        bday = Arel.sql("(ts / 86400) * 86400")
        Burn.where(chain_id: @chain.id, token: @chain.addr(:par), from_addr: @chain.addr(:buyback_wallet))
            .where(ts: start_day...(end_day + 86_400)).group(bday).sum(:amount).transform_values { _1.to_f / 1e18 }
      end
      usd = Pricing.new(@chain).ref_usd
      payouts = payouts_by_day(start_day, end_day)
      rounds = Distribution.where(chain_id: @chain.id, ts: start_day...(end_day + 86_400)).group(Arel.sql("(ts / 86400) * 86400")).count
      axis = (start_day..end_day).step(86_400).to_a
      {
        range: RANGES.key?(range) ? range : "30d", from: start_day, to: end_day, refUsd: usd, refSymbol: @chain.reference[:symbol],
        days: axis.map do |d|
          n, vol, traders = tday[d] || [0, 0, 0]
          creator, proto = fees[d] || [0, 0]
          { day: d, volumeEth: vol.to_f, volumeUsd: vol.to_f * usd, trades: n, traders:, launches: launches[d] || 0,
            creatorFeesUsd: creator * usd, protocolFeesUsd: proto * usd, parBurned: buybacks&.dig(d) || 0,
            payoutsUsd: payouts[d]&.first.to_f * usd, walletsPaid: payouts[d]&.last.to_i, payoutRounds: rounds[d] || 0 }
        end
      }
    end

    # Every enabled chain at once, in USD: per-chain stats/daily converted with each chain's ref→USD rate.
    def self.all_chains(range)
      chains = Chains.enabled
      per = chains.map { |c| q = new(c); [c, q.stats] }
      last = chains.filter_map { |c| Trade.where(chain_id: c.id).maximum(:ts) }.max || Time.now.to_i
      end_day = last - last % 86_400
      # one shared axis: with "all" the chains start on different days
      first = chains.filter_map { |c| Launch.where(chain_id: c.id).minimum(:launched_at) }.min if range == "all"
      start_day = first && first - first % 86_400
      dailies = chains.map { |c| new(c).daily(range, end_day:, start_day:) }
      days = dailies.first[:days].each_with_index.map do |d, i|
        sum = ->(k) { dailies.sum { _1[:days][i][k] } }
        d.merge(volumeUsd: sum.(:volumeUsd), trades: sum.(:trades), traders: sum.(:traders), launches: sum.(:launches),
                creatorFeesUsd: sum.(:creatorFeesUsd), protocolFeesUsd: sum.(:protocolFeesUsd), parBurned: sum.(:parBurned),
                payoutsUsd: sum.(:payoutsUsd), walletsPaid: sum.(:walletsPaid), payoutRounds: sum.(:payoutRounds))
      end
      usd = ->(k) { per.sum { |_, st| st[k].to_f * st[:refUsd].to_f } }
      int = ->(k) { per.sum { |_, st| st[k].to_i } }
      stats = {
        refSymbol: "USD", refUsd: 1.0, volumeEth: usd.(:volumeEth), volume24hEth: usd.(:volume24hEth),
        creatorEarnedEth: usd.(:creatorEarnedEth), protocolFeesEth: usd.(:protocolFeesEth),
        creatorFeesGenEth: usd.(:creatorFeesGenEth), protocolFeesGenEth: usd.(:protocolFeesGenEth),
        launches: int.(:launches), launches24h: int.(:launches24h), launchesTraded: int.(:launchesTraded),
        trades: int.(:trades), trades24h: int.(:trades24h), holders: int.(:holders), tokensWithHolders: int.(:tokensWithHolders),
        holderWallets: int.(:holderWallets), traderWallets: int.(:traderWallets), payoutsEth: usd.(:payoutsEth), payouts: int.(:payouts),
        par: per.map(&:last).filter_map { _1[:par] }.first,
        feeModes: %w[creator holders burn floor].map do |m|
          { mode: m, launches: per.sum { |_, st| st[:feeModes].find { _1[:mode] == m }[:launches] },
            creatorFeesEth: per.sum { |_, st| st[:feeModes].find { _1[:mode] == m }[:creatorFeesEth] * st[:refUsd].to_f } }
        end,
        mirror: { since: nil, launches: per.sum { _2[:mirror][:launches] }, volumeEth: per.sum { |_, st| st[:mirror][:volumeEth] * st[:refUsd].to_f },
                  creatorFeesEth: per.sum { |_, st| st[:mirror][:creatorFeesEth] * st[:refUsd].to_f },
                  protocolFeesEth: per.sum { |_, st| st[:mirror][:protocolFeesEth] * st[:refUsd].to_f } }
      }
      [stats, dailies.first.merge(days:, refUsd: 1.0, refSymbol: "USD")]
    end

    def stats
      Rails.cache.fetch("par/stats/#{@chain.id}", expires_in: 30.seconds) do
        r = rows
        t24 = 24.hours.ago.to_i
        trades = Trade.where(chain_id: @chain.id)
        holders = LaunchRows.new(@chain).holders_count
        par = @chain.addr(:par) != Chains::ZERO ? r.find { _1[:token] == @chain.addr(:par) } : nil
        day = Arel.sql("(ts / 86400) * 86400")
        {
          chainId: @chain.id, at: Time.now.to_i, refSymbol: @chain.reference[:symbol], refUsd: Pricing.new(@chain).ref_usd,
          launches: r.size, launches24h: r.count { _1[:createdAt].to_i > t24 }, launchesTraded: r.count { _1[:tradeCount].positive? },
          holders: holders.values.sum, tokensWithHolders: holders.size,
          holderWallets: Balance.where(chain_id: @chain.id).where("balance > 0").where.not(owner: system).distinct.count(:owner),
          traderWallets: trades.distinct.count(:trader),
          payoutsEth: payouts_by_day(0, Time.now.to_i).values.sum(&:first), payouts: Reward.where(chain_id: @chain.id).count,
          trades: trades.count, trades24h: trades.where("ts > ?", t24).count,
          volumeEth: trades.sum(:value_eth), volume24hEth: trades.where("ts > ?", t24).sum(:value_eth),
          creatorEarnedEth: r.sum { _1[:creatorFeesEth] }, protocolFeesEth: r.sum { _1[:protocolFeesEth] },
          # what trades generated (value × fee at trade time), the same measure as the daily series
          **Trade.from("trades t").joins("JOIN launches l ON l.chain_id = t.chain_id AND l.token = t.token").where("t.chain_id = ?", @chain.id)
                 .pick(Arel.sql("SUM(t.value_eth * l.pool_fee / 1e6)"), Arel.sql("SUM(t.value_eth * l.base_fee_bps / 1e4 * l.protocol_fee_share_bps / 1e4)"))
                 .then { |total, proto| { creatorFeesGenEth: total.to_f - proto.to_f, protocolFeesGenEth: proto.to_f } },
          feeModes: %w[creator holders burn floor].map { |m| sel = r.select { _1[:feeMode] == m }; { mode: m, launches: sel.size, creatorFeesEth: sel.sum { _1[:creatorFeesEth] } } },
          par: par && { token: par[:token], priceEth: par[:lastPriceEth], burned: par[:burnedToken] },
          mirror: r.select { _1[:viaMirror] }.then do |m|
            { since: MirrorTag.since_block(@chain.id), launches: m.size, volumeEth: m.sum { _1[:totalVolumeEth] },
              creatorFeesEth: m.sum { _1[:creatorFeesEth] }, protocolFeesEth: m.sum { _1[:protocolFeesEth] } }
          end,
          daily: trades.group(day).order(day).pluck(day, Arel.sql("COUNT(*)"), Arel.sql("SUM(value_eth)"), Arel.sql("COUNT(DISTINCT trader)"))
                       .map { |d, n, v, u| { day: d, trades: n, volumeEth: v.to_f, traders: u } },
          launchesDaily: Launch.where(chain_id: @chain.id).group(Arel.sql("(launched_at / 86400) * 86400")).count.sort.map { |d, n| { day: d, n: } }
        }
      end
    end

    # Holder payouts per day: { day => [value in the reference asset, distinct wallets paid] }.
    # Valued at today's prices (ETH as is, the launch token at its last price, quotes through the pricer).
    def payouts_by_day(start_day, end_day)
      day = Arel.sql("(ts / 86400) * 86400")
      scope = Reward.where(chain_id: @chain.id, ts: start_day...(end_day + 86_400))
      per_asset = scope.group(day, :asset).sum(:amount)
      wallets = scope.group(day).distinct.count(:owner)
      price = Hash.new { |h, a| h[a] = asset_eth(a) }
      out = Hash.new { |h, k| h[k] = [0.0, 0] }
      per_asset.each { |(d, asset), amt| out[d][0] += amt.to_f * price[asset] }
      wallets.each { |d, n| out[d][1] = n }
      out
    end

    # ETH (reference) per raw unit of a payout asset; launch tokens from the cached launch rows
    def asset_eth(asset)
      return 1e-18 if asset == Chains::ZERO
      @row_prices ||= rows.to_h { [_1[:token], [_1[:lastPriceEth].to_f, _1[:decimals] || 18]] }
      if (p = @row_prices[asset])
        p[0] / 10**p[1]
      else
        dec = QuoteAsset.where(chain_id: @chain.id, pair_token: asset).pick(:decimals) || 18
        (@pricing ||= Pricing.new(@chain)).quote_eth(asset).to_f / 10**dec
      end
    end

    # Top tokens of a window ($par left out), values in the reference asset
    def leaders(start_day, end_day, limit: 10)
      window = start_day...(end_day + 86_400)
      par = @chain.addr(:par)
      t = Trade.from("trades t").where("t.chain_id = ? AND t.ts >= ? AND t.ts < ?", @chain.id, window.begin, window.end).where.not("t.token = ?", par)
      volume = t.group("t.token").order(Arel.sql("SUM(t.value_eth) DESC")).limit(limit).pluck("t.token", Arel.sql("SUM(t.value_eth)"))
      fees = t.joins("JOIN launches l ON l.chain_id = t.chain_id AND l.token = t.token").group("t.token")
              .order(Arel.sql("2 DESC")).limit(limit)
              .pluck("t.token", Arel.sql("SUM(t.value_eth * (l.pool_fee / 1e6 - l.base_fee_bps / 1e4 * l.protocol_fee_share_bps / 1e4))"))
      paid = Reward.where(chain_id: @chain.id, ts: window).where.not(token: par).group(:token, :asset).sum(:amount)
      price = Hash.new { |h, a| h[a] = asset_eth(a) }
      payouts = paid.each_with_object(Hash.new(0.0)) { |((tok, asset), amt), h| h[tok] += amt.to_f * price[asset] }.sort_by { -_2 }.first(limit)
      meta = Launch.where(chain_id: @chain.id, token: (volume + fees + payouts).map(&:first).uniq).pluck(:token, :symbol, :name).to_h { [_1, { symbol: _2, name: _3 }] }
      row = ->((tok, v)) { { chainId: @chain.id, chain: @chain.slug, token: tok, valueEth: v.to_f, **(meta[tok] || {}) } }
      { volume: volume.map(&row), fees: fees.map(&row), payouts: payouts.map(&row) }
    end
  end
end
