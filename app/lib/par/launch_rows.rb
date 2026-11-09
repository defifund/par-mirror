module Par
  # Launch rows in the shape of the original public indexer (par-sdk INTEGRATION.md A8), plus a few
  # derived fields (USD values, 24h volume, holders). Shared by the HTML pages and the JSON API.
  class LaunchRows
    SORTS = {
      "createdAt" => ->(r) { r[:createdBlock] }, "new" => ->(r) { r[:createdBlock] },
      "lastTradeAt" => ->(r) { r[:lastTradeAt].to_i }, "tradeCount" => ->(r) { r[:tradeCount] },
      # USD keys so rows of different chains (ETH, USDC, BNB references) sort together
      "totalVolumeQuote" => ->(r) { r[:totalVolumeUsd] }, "volume" => ->(r) { r[:totalVolumeUsd] },
      "marketCap" => ->(r) { r[:marketCapUsd] }, "recentVolume" => ->(r) { r[:recentVolumeUsd] },
      "holders" => ->(r) { r[:holders] }
    }.freeze

    # Every page reads these rows (3.6k launches on Robinhood Chain, ~12 MB), so each Puma process keeps its own copy
    # in memory, indexed by token. Requests never wait for a rebuild: at most every CHECK a background thread looks at
    # a tiny per-chain version number and reloads only when it moved (the indexer bumps it after a range with
    # launches, swaps or transfers; quote refreshes and creator edits bump it too) or the copy is older than MAX_AGE
    # (the 24 h volume window, fee and payout events). The reload goes through Rails.cache, keyed by that version, so
    # the two processes share one build (1–3 s of queries). Only a process's very first read of a chain waits.
    CHECK = 10.seconds
    MAX_AGE = 5.minutes
    Copy = Struct.new(:rows, :by_token, :version, :built_at, :checked_at)
    @copies = {}
    @lock = Mutex.new # guards @copies/@refreshing bookkeeping
    @first_load = Mutex.new # one cold build at a time per process
    @refreshing = {}

    class << self
      def for(chain) = copy(chain).rows

      def find(chain, token) = copy(chain).by_token[token.to_s.downcase]

      # data behind the rows changed; every process reloads within CHECK
      def changed!(chain_id)
        Rails.cache.write(version_key(chain_id), SecureRandom.hex(6))
      end

      # a creator just edited their token: also drop this process's copy so their redirect shows the edit
      def expire(chain_id)
        changed!(chain_id)
        @lock.synchronize { @copies.delete(chain_id) }
      end

      private

      def version_key(chain_id) = "par/rows/v/#{chain_id}"

      def load(chain)
        v = Rails.cache.read(version_key(chain.id)).to_s
        bucket = Time.now.to_i / MAX_AGE.to_i
        rows = Rails.cache.fetch("par/rows/#{chain.id}/#{v}/#{bucket}", expires_in: MAX_AGE * 2) { new(chain).build }
        now = Time.now
        Copy.new(rows, rows.index_by { _1[:token] }, v, now, now)
      end

      def copy(chain)
        return load(chain) if Rails.env.test? # no state carried between tests

        c = @copies[chain.id] || @first_load.synchronize { @copies[chain.id] ||= load(chain) }
        refresh_later(chain) if Time.now - c.checked_at > CHECK
        c
      end

      def refresh_later(chain)
        @lock.synchronize do
          return if @refreshing[chain.id]

          @refreshing[chain.id] = true
        end
        Thread.new do
          Rails.application.executor.wrap do
            c = @copies[chain.id]
            if c && Rails.cache.read(version_key(chain.id)).to_s == c.version && Time.now - c.built_at < MAX_AGE
              c.checked_at = Time.now
            else
              @copies[chain.id] = load(chain)
            end
          end
        rescue => e
          Rails.logger.error("[launch_rows] refresh #{chain.slug} failed: #{e.class}: #{e.message}")
        ensure
          @lock.synchronize { @refreshing.delete(chain.id) }
        end
      end
    end

    def self.filter(rows, params)
      out = rows
      if (q = params[:q].to_s.strip.downcase).present?
        out = out.select { |r| r[:token] == q || r[:name].to_s.downcase.include?(q) || r[:symbol].to_s.downcase.include?(q) }
      end
      out = out.select { _1[:deployer] == params[:deployer].downcase } if params[:deployer].present?
      if params[:token_in].present?
        set = params[:token_in].downcase.split(",").to_set
        out = out.select { set.include?(_1[:token]) }
      end
      out = out.select { _1[:feeMode] == params[:feeMode] } if params[:feeMode].present?
      out = out.select { _1[:feesToHolders] } if params[:feesToHolders] == "1"
      key = SORTS[params[:orderBy].presence || "createdAt"] || SORTS["createdAt"]
      out = out.sort_by(&key)
      out = out.reverse unless params[:orderDirection] == "asc"
      limit = (params[:limit].presence || 100).to_i.clamp(1, 500)
      offset = [params[:offset].to_i, 0].max
      [out.size, out[offset, limit] || []]
    end

    def initialize(chain)
      @chain = chain
      @pricing = Pricing.new(chain)
    end

    def holders_count
      Balance.where(chain_id: @chain.id).where("balance > 0").where.not(owner: Indexer.new(@chain).system_addresses).group(:token).count
    end

    def build
      c = @chain
      usd = @pricing.ref_usd
      recent = Trade.where(chain_id: c.id).where("ts > ?", 24.hours.ago.to_i).group(:token).sum(:value_eth)
      holders = holders_count
      in_pools = Balance.where(chain_id: c.id, owner: c.addr(:pool_manager)).pluck(:token, :balance).to_h
      markets = Market.where(chain_id: c.id).order(:token, :idx).group_by(&:token)
      floors = Payouts.new(c).floor_by_token
      edits = TokenProfile.where(chain_id: c.id).index_by(&:token) # the creator's corrections, made on this mirror
      Launch.where(chain_id: c.id).map do |l|
        ms = markets[l.token] || []
        m_rows = ms.map { market_row(_1) }
        m0 = m_rows.first || {}
        price = @pricing.token_price_eth(l.token)
        circ = l.circulating.to_f / 1e18
        mode = l.fee_mode
        creator_eth = m_rows.sum { _1[:_creatorEth] }
        s = l.socials || {}
        ed = edits[l.token]
        s = s.merge(ed.socials) if ed
        logo = ed&.logo || l.logo.presence
        {
          chainId: c.id, chain: c.slug, launchpad: "par", factory: l.factory, locker: l.locker, kind: l.kind,
          marketCount: ms.size, markets: ms.size > 1 ? m_rows.map { |r| r.reject { |k, _| k.start_with?("_") } } : nil,
          token: l.token, poolId: m0[:poolId], poolFee: l.pool_fee, tickSpacing: l.tick_spacing,
          feesToHolders: mode == "holders", feesBurned: mode == "burn", feesFloor: mode == "floor", feeMode: mode, floor: mode == "floor" ? (floors[l.token] || []) : nil,
          deployer: l.deployer, creatorFeeRecipient: l.creator_fee_recipient,
          name: l.name, symbol: l.symbol, decimals: l.decimals, logo:, logoUrl: Pricing.http_url(logo), description: ed&.description || l.description.presence,
          editedOnMirror: ed.present?,
          socials: %w[twitter telegram discord website farcaster].to_h { [_1.to_sym, s[_1].presence] },
          pairToken: m0[:pairToken], quoteSymbol: m0[:quoteSymbol], quoteDecimals: m0[:quoteDecimals], quoteRisk: m0[:quoteRisk],
          launchConfigId: l.launch_config_id, phantomQuote: m0[:phantomQuote], supply: l.supply.to_i.to_s,
          baseFeeBps: l.base_fee_bps, creatorTaxBps: l.creator_tax_bps, protocolFeeShareBps: l.protocol_fee_share_bps, protocolFeeRecipient: l.protocol_fee_recipient,
          quoteRaised: m0[:quoteRaised], tokensOnCurve: in_pools[l.token].to_i.to_s, totalVolumeQuote: m0[:totalVolumeQuote],
          totalVolumeEth: m_rows.sum { _1[:_volEth] }, totalVolumeUsd: m_rows.sum { _1[:_volEth] } * usd,
          creatorFeesQuote: m0[:creatorFeesQuote], creatorFeesToken: m0[:creatorFeesToken],
          creatorFeesEth: creator_eth, creatorFeesUsd: creator_eth * usd, protocolFeesEth: m_rows.sum { _1[:_protocolEth] },
          burnedToken: l.burned.to_i.to_s, tradeCount: ms.sum(&:trade_count),
          lastPriceQuoteX18: m0[:lastPriceQuoteX18], lastPriceEth: price, lastPriceUsd: price * usd,
          marketCapEth: price * circ, marketCapUsd: price * circ * usd,
          recentVolumeEth: recent[l.token].to_f, recentVolumeUsd: recent[l.token].to_f * usd, holders: holders[l.token].to_i,
          createdAt: l.launched_at, createdBlock: l.launch_block, launchTx: l.launch_tx, viaMirror: l.via_mirror,
          lastTradeAt: ms.map { _1.last_trade_at.to_i }.max.then { _1&.positive? ? _1 : nil },
          positionId: m0[:positionId]
        }
      end
    end

    private

    def quote_risk(pair)
      return "native" if pair == Chains::ZERO
      return "verified" if self.class.verified(@chain.id).include?(pair) || [@chain.addr(:usdg), @chain.addr(:par)].include?(pair)
      "wild"
    end

    # config/par/verified_quotes_<chain>.txt: "<address> <symbol>" per line, from the original indexer's classification
    def self.verified(chain_id)
      @verified ||= {}
      @verified[chain_id] ||= begin
        f = Rails.root.join("config/par/verified_quotes_#{chain_id}.txt")
        f.exist? ? f.readlines.reject { _1.start_with?("#") }.filter_map { _1.split.first&.downcase }.to_set : Set.new
      end
    end

    def market_row(m)
      qe = @pricing.quote_eth(m.pair_token)
      px = m.last_price_x18.to_f / 10**m.quote_decimals
      tok_px = px * qe
      {
        index: m.idx, poolId: m.pool_id, pairToken: m.pair_token, quoteSymbol: m.quote_symbol, quoteDecimals: m.quote_decimals,
        quoteRisk: quote_risk(m.pair_token), phantomQuote: m.phantom_quote.to_i.to_s, positionId: m.position_id.to_i.to_s,
        quoteRaised: m.quote_raised.to_i.to_s, tokensOnCurve: m.tokens_on_curve.to_s, totalVolumeQuote: m.volume_quote.to_i.to_s,
        tradeCount: m.trade_count, creatorFeesQuote: m.creator_fees_quote.to_i.to_s, creatorFeesToken: m.creator_fees_token.to_i.to_s,
        lastPriceQuoteX18: Pricing.x18_s(m.last_price_x18), lastPriceEth: tok_px, lastTradeAt: m.last_trade_at,
        _volEth: m.volume_quote.to_f / 10**m.quote_decimals * qe,
        _creatorEth: m.creator_fees_quote.to_f / 10**m.quote_decimals * qe + m.creator_fees_token.to_f / 1e18 * tok_px,
        _protocolEth: m.protocol_fees_quote.to_f / 10**m.quote_decimals * qe
      }
    end
  end
end
