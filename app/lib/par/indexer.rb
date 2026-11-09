module Par
  # Replays par's on-chain history into Postgres, one block range at a time:
  #   1. factory / locker logs  -> launches, markets, fee collections, recipient changes
  #   2. PoolManager Swap logs filtered to par pool ids -> trades + market aggregates
  #   3. Transfer logs of par tokens -> balances + burns
  # Everything a range writes is committed together with the cursor, so a crash never double counts.
  class Indexer
    Q192 = 2**192
    WAD = 10**18

    attr_reader :chain, :rpc

    def initialize(chain)
      @chain = chain
      @rpc = Rpc.new(chain)
      @ts_cache = {}
      @config_supply = {}
    end

    def state
      @state ||= SyncState.find_or_create_by!(chain_id: chain.id) { |s| s.cursor_block = chain.deploy_block - 1 }
    end

    def system_addresses
      @system_addresses ||= [Chains::ZERO, Chains::DEAD, chain.addr(:pool_manager), chain.addr(:locker), chain.addr(:multi_locker),
                             chain.addr(:fee_escrow), chain.position_manager.downcase].uniq
    end

    # Process ranges until `deadline` (monotonic seconds) or the head is reached. Returns the number of ranges done.
    def run_until(deadline)
      refresh_quotes if state.quotes_refreshed_at.nil? # first run only; RefreshQuotesJob keeps them fresh
      head = rpc.block_number
      # PAR_STOP_AT_<chain>: freeze the index at a block (e.g. to compare against another index of the same range)
      stop = ENV["PAR_STOP_AT_#{chain.id}"]&.to_i
      head = [head, stop].min if stop&.positive?
      state.update!(head_block: head)
      done = 0
      while state.cursor_block < head && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        from = state.cursor_block + 1
        to = [from + chain.log_span - 1, head].min
        t0 = Time.now
        r = process_range(from, to)
        LaunchRows.changed!(chain.id) if (r[:launches] + r[:swaps] + r[:transfers]).positive?
        done += 1
        lag = head - to
        state.update!(backfilling: lag > 50, last_error: nil)
        Rails.logger.info("[par #{chain.slug}] #{from}-#{to} +#{r[:launches]} launches +#{r[:swaps]} swaps +#{r[:transfers]} transfers " \
                          "(#{((Time.now - t0) * 1000).round}ms #{r[:timing].map { "#{_1}=#{_2}" }.join(' ')}, #{progress.round(1)}%, lag #{lag})")
      end
      state.update!(backfilling: false) if state.cursor_block >= head
      done
    rescue StandardError => e
      state.update_columns(last_error: "#{e.class}: #{e.message}"[0, 400], updated_at: Time.current)
      raise
    end

    def progress = state.progress

    # ---------- one range ----------
    def process_range(from, to)
      @timing = {}
      lap = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      tick = ->(k) { now = Process.clock_gettime(Process::CLOCK_MONOTONIC); @timing[k] = ((now - lap) * 1000).round; lap = now }
      a = chain.addresses.transform_values(&:downcase)
      proto = [a[:factory], a[:multi_factory], a[:locker], a[:multi_locker]].reject { _1 == Chains::ZERO }
      proto_logs = logs_safe(from, to, address: proto)
      tick.(:proto)

      by = ->(addr, ev) { proto_logs.select { |l| l["address"].downcase == addr && l["topics"][0] == ev.topic0 }.map { |l| [l, Abi.decode_log(ev, l)] } }
      minted = by.(a[:factory], Events::POSITION_MINTED)
      opened = by.(a[:multi_factory], Events::MARKET_OPENED)
      known_tokens = Launch.where(chain_id: chain.id).pluck(:token).to_set

      new_launches = by.(a[:factory], Events::TOKEN_LAUNCHED).map do |l, e|
        amt = minted.find { |_, m| m[:token] == e[:token] }&.last&.dig(:tokenAmount) || 0
        { token: e[:token], kind: "single", pool_ids: [e[:poolId]], token_amounts: [amt], config_id: e[:launchConfigId], block: l["blockNumber"].to_i(16), tx: l["transactionHash"] }
      end
      new_launches += by.(a[:multi_factory], Events::MULTI_LAUNCHED).map do |l, e|
        mine = opened.select { |_, o| o[:token] == e[:token] }.sort_by { |_, o| o[:marketIndex] }
        { token: e[:token], kind: "multi", pool_ids: mine.map { _2[:poolId] }, token_amounts: mine.map { _2[:tokenAmount] }, config_id: e[:launchConfigId],
          block: l["blockNumber"].to_i(16), tx: l["transactionHash"] }
      end
      new_launches.reject! { known_tokens.include?(_1[:token]) }

      pools = Market.where(chain_id: chain.id).pluck(:pool_id, :token, :idx, :token_is_c0, :quote_decimals, :pair_token)
                    .to_h { |pid, *rest| [pid, rest] }
      pool_ids = pools.keys + new_launches.flat_map { _1[:pool_ids] }
      tokens = known_tokens.to_a + new_launches.map { _1[:token] }

      swap_logs = rpc.pmap(pool_ids.each_slice(chain.max_addresses).to_a, threads: 4) do |ids|
        logs_safe(from, to, address: a[:pool_manager], topics: [Events::SWAP.topic0, ids])
      end.flatten
      transfer_logs = rpc.pmap(tokens.each_slice(chain.max_addresses).to_a, threads: 4) do |ts|
        logs_safe(from, to, address: ts, topics: [Events::TRANSFER.topic0])
      end.flatten

      tick.(:logs)
      blocks = (proto_logs + swap_logs + transfer_logs).map { _1["blockNumber"].to_i(16) }.uniq
      ts = blocks.any? ? timestamps(blocks, to) : {}
      # launch times exact, like the original indexer (trades stay interpolated: ≤ ~10 s off)
      new_launches.map { _1[:block] }.uniq.each { |b| ts[b] = exact_ts(b) }
      tick.(:ts)

      register(new_launches, ts) if new_launches.any?
      tick.(:register)
      if new_launches.any?
        Market.where(chain_id: chain.id, token: new_launches.map { _1[:token] })
              .pluck(:pool_id, :token, :idx, :token_is_c0, :quote_decimals, :pair_token).each { |pid, *rest| pools[pid] = rest }
      end

      swaps = write_range(to, ts, pools, proto_logs, swap_logs, transfer_logs, a)
      tick.(:write)
      { launches: new_launches.size, swaps:, transfers: transfer_logs.size, timing: @timing }
    end

    def write_range(to, ts, pools, proto_logs, swap_logs, transfer_logs, a)
      now = Time.current
      trade_rows = []
      market_delta = Hash.new { |h, k| h[k] = { quote_raised: 0, tokens_sold: 0, volume_quote: 0, trade_count: 0, last: nil } }
      quote_eth_cache = {}
      pm = a[:pool_manager]
      # token transfers per (tx, token), to tell who paid or received the tokens of each swap
      transfers = transfer_logs.uniq { [_1["blockNumber"], _1["logIndex"]] }.map { [_1, Abi.decode_log(Events::TRANSFER, _1)] }
      by_tx = transfers.group_by { |l, _| [l["transactionHash"], l["address"].downcase] }

      swap_logs.sort_by { [_1["blockNumber"].to_i(16), _1["logIndex"].to_i(16)] }.each do |l|
        e = Abi.decode_log(Events::SWAP, l)
        pid = e[:id]
        token, idx, c0, qdec, pair = pools[pid]
        next unless token
        token_delta, quote_delta = c0 ? [e[:amount0], e[:amount1]] : [e[:amount1], e[:amount0]]
        buy = token_delta.positive?
        tok_amt, q_amt = token_delta.abs, quote_delta.abs
        px = price_x18(e[:sqrtPriceX96], c0)
        qe = (quote_eth_cache[pair] ||= quote_eth(pair))
        block = l["blockNumber"].to_i(16)
        t = ts[block] || 0
        trade_rows << {
          chain_id: chain.id, block_number: block, log_index: l["logIndex"].to_i(16), tx_hash: l["transactionHash"], ts: t,
          pool_id: pid, token:, market: idx, sender: e[:sender], trader: trader_of(by_tx[[l["transactionHash"], token]], l["logIndex"].to_i(16), buy, pm), is_buy: buy, quote_amount: q_amt, token_amount: tok_amt,
          fee: e[:fee], price_x18: px, price_eth: px.to_f / 10**qdec * qe, quote_eth: qe, value_eth: q_amt.to_f / 10**qdec * qe
        }
        d = market_delta[pid]
        d[:quote_raised] += buy ? q_amt : -q_amt
        d[:tokens_sold] += buy ? tok_amt : -tok_amt
        d[:volume_quote] += q_amt
        d[:trade_count] += 1
        d[:last] = [px, t]
      end

      balance_delta = Hash.new(0)
      burn_rows = []
      burned_delta = Hash.new(0)
      transfers.each do |l, e|
        tok = l["address"].downcase
        balance_delta[[tok, e[:from]]] -= e[:value] unless e[:from] == Chains::ZERO
        if e[:to] == Chains::ZERO || e[:to] == Chains::DEAD
          block = l["blockNumber"].to_i(16)
          burn_rows << { chain_id: chain.id, block_number: block, log_index: l["logIndex"].to_i(16), tx_hash: l["transactionHash"], ts: ts[block] || 0,
                         token: tok, from_addr: e[:from], amount: e[:value] }
          burned_delta[tok] += e[:value]
        end
        balance_delta[[tok, e[:to]]] += e[:value] unless e[:to] == Chains::ZERO
      end

      fee_rows = []
      fee_delta = Hash.new { |h, k| h[k] = Hash.new(0) }
      collect = lambda do |ev, addr, &market_of|
        proto_logs.select { _1["address"].downcase == addr && _1["topics"][0] == ev.topic0 }.each do |l|
          e = Abi.decode_log(ev, l)
          m = market_of.(e)
          block = l["blockNumber"].to_i(16)
          fee_rows << { chain_id: chain.id, block_number: block, log_index: l["logIndex"].to_i(16), tx_hash: l["transactionHash"], ts: ts[block] || 0,
                        token: e[:token], market: m, currency0: e[:currency0], currency1: e[:currency1],
                        protocol0: e[:protocolAmount0], protocol1: e[:protocolAmount1], creator0: e[:creatorAmount0], creator1: e[:creatorAmount1] }
        end
      end
      collect.(Events::FEES_COLLECTED, a[:locker]) { 0 }
      collect.(Events::MULTI_FEES_COLLECTED, a[:multi_locker]) { _1[:marketIndex] }
      recipients = proto_logs.select { [a[:factory], a[:multi_factory]].include?(_1["address"].downcase) && _1["topics"][0] == Events::RECIPIENT_UPDATED.topic0 }
                             .map { Abi.decode_log(Events::RECIPIENT_UPDATED, _1) }

      ActiveRecord::Base.transaction do
        Trade.insert_all(trade_rows, unique_by: %i[chain_id block_number log_index]) if trade_rows.any?
        market_delta.each do |pid, d|
          px, t = d[:last]
          Market.where(chain_id: chain.id, pool_id: pid).update_all([
            "quote_raised = quote_raised + ?, tokens_sold = tokens_sold + ?, volume_quote = volume_quote + ?, trade_count = trade_count + ?, last_price_x18 = ?, last_trade_at = ?",
            d[:quote_raised], d[:tokens_sold], d[:volume_quote], d[:trade_count], px, t
          ])
        end
        if balance_delta.any?
          rows = balance_delta.reject { |_, v| v.zero? }.map { |(tok, owner), v| { chain_id: chain.id, token: tok, owner:, balance: v } }
          rows.each_slice(5000) do |slice|
            Balance.upsert_all(slice, unique_by: %i[chain_id token owner], on_duplicate: Arel.sql("balance = balances.balance + EXCLUDED.balance"))
          end
        end
        Burn.insert_all(burn_rows, unique_by: %i[chain_id block_number log_index]) if burn_rows.any?
        burned_delta.each { |tok, v| Launch.where(chain_id: chain.id, token: tok).update_all(["burned = burned + ?", v]) }
        if fee_rows.any?
          FeeCollection.insert_all(fee_rows, unique_by: %i[chain_id block_number log_index])
          fee_rows.each do |f|
            m = Market.find_by(chain_id: chain.id, token: f[:token], idx: f[:market]) or next
            cq, ct = m.token_is_c0 ? [f[:creator1], f[:creator0]] : [f[:creator0], f[:creator1]]
            pq, pt = m.token_is_c0 ? [f[:protocol1], f[:protocol0]] : [f[:protocol0], f[:protocol1]]
            Market.where(id: m.id).update_all(["creator_fees_quote = creator_fees_quote + ?, creator_fees_token = creator_fees_token + ?, " \
                                               "protocol_fees_quote = protocol_fees_quote + ?, protocol_fees_token = protocol_fees_token + ?", cq, ct, pq, pt])
          end
        end
        recipients.each { |r| Launch.where(chain_id: chain.id, token: r[:token]).update_all(creator_fee_recipient: r[:newRecipient], updated_at: now) }
        state.update!(cursor_block: to)
      end
      trade_rows.size
    end

    # Who traded: the address the PoolManager paid the tokens to (buy) or took them from (sell), i.e. the
    # transfer touching the PoolManager nearest to the swap in the same transaction, then followed through
    # intermediaries (routers forward the tokens on: later in the tx for a buy, earlier for a sell).
    # For a wallet this ends at tx.from; for a bot or vault that keeps the tokens it ends at that contract.
    # nil -> resolved later via tx.from.
    def trader_of(token_transfers, swap_index, buy, pm)
      return nil if token_transfers.blank?
      idx = ->(l) { l["logIndex"].to_i(16) }
      cands = token_transfers.select { |_, e| buy ? e[:from] == pm : e[:to] == pm }
      best = cands.min_by { |l, _| (idx.(l) - swap_index).abs } or return nil
      addr, at = (buy ? best.last[:to] : best.last[:from]), idx.(best.first)
      # an address that both takes the token from and settles it back to the PoolManager in this tx is a
      # routing hop (the token is an intermediate of someone else's route): let tx.from decide
      took = token_transfers.any? { |_, e| e[:from] == pm && e[:to] == addr }
      gave = token_transfers.any? { |_, e| e[:to] == pm && e[:from] == addr }
      return nil if took && gave && !bot_like?(token_transfers, addr, pm)
      3.times do
        nxt = if buy
          token_transfers.select { |l, e| e[:from] == addr && idx.(l) > at && e[:to] != pm }.min_by { idx.(_1.first) }
        else
          token_transfers.select { |l, e| e[:to] == addr && idx.(l) < at && e[:from] != pm }.max_by { idx.(_1.first) }
        end
        break unless nxt
        cand = buy ? nxt.last[:to] : nxt.last[:from]
        break if cand == Chains::ZERO || cand == Chains::DEAD # burns / mints end the trail
        addr, at = cand, idx.(nxt.first)
      end
      addr == Chains::ZERO ? nil : addr
    end

    # an arbitrage contract also takes and settles, but in different pools of the same token; a pure
    # routing hop moves the same amount out and back. Treat equal in/out as a hop.
    def bot_like?(token_transfers, addr, pm)
      ins = token_transfers.select { |_, e| e[:from] == pm && e[:to] == addr }.sum { _2[:value] }
      outs = token_transfers.select { |_, e| e[:to] == pm && e[:from] == addr }.sum { _2[:value] }
      ins != outs
    end

    # ---------- launches ----------
    def register(launches, ts)
      a = chain.addresses.transform_values(&:downcase)
      # one Multicall3 round trip for every read of every new launch in the range
      per = launches.map do |l|
        tok = l[:token]
        factory = l[:kind] == "single" ? a[:factory] : a[:multi_factory]
        reads = [[tok, "name()", [], ["string"]], [tok, "symbol()", [], ["string"]], [tok, "decimals()", [], ["uint8"]],
                 [tok, "getTokenInfo()", [], Events::TOKEN_INFO],
                 [factory, "getLaunchedToken(address)", [tok], [l[:kind] == "single" ? Events::LAUNCHED_TOKEN : Events::MULTI_LAUNCHED_TOKEN]]]
        reads << [factory, "getMarkets(address)", [tok], [Events::MARKETS]] if l[:kind] == "multi"
        [l, factory, reads]
      end
      results = rpc.multi_read(per.flat_map(&:last))
      since = MirrorTag.since_block(chain.id)
      tagged = rpc.pmap(launches.select { _1[:block] >= since }.map { _1[:tx] }.uniq, threads: 6) do |h|
        [h, MirrorTag.in_calldata?(rpc.request("eth_getTransactionByHash", [h])&.dig("input"))]
      end.to_h
      reads = per.map do |l, factory, rs|
        name, symbol, decimals, info, rec_raw, markets_raw = results.shift(rs.size)
        raise "launch #{l[:token]}: factory record unreadable" unless rec_raw
        if l[:kind] == "single"
          rec = Events::LAUNCHED_TOKEN_FIELDS.zip(rec_raw.first).to_h
          markets = [rec.slice(:pair_token, :phantom_quote, :tick_lower, :tick_upper, :position_id)]
        else
          rec = Events::MULTI_LAUNCHED_TOKEN_FIELDS.zip(rec_raw.first).to_h
          markets = markets_raw.first.map { Events::MARKET_FIELDS.zip(_1).to_h }
        end
        metas = markets.map { quote_meta(_1[:pair_token]) }
        { l:, name: name&.first.to_s, symbol: symbol&.first.to_s, decimals: decimals&.first || 18, info:, rec:, markets:, metas:, factory:,
          supply: supply_for(factory, l[:config_id]) }
      end

      ActiveRecord::Base.transaction do
        reads.each do |r|
          l, rec = r[:l], r[:rec]
          socials = r[:info] ? %w[twitter telegram discord website farcaster].zip(r[:info][3]).to_h : {}
          launch = Launch.create!(
            chain_id: chain.id, token: l[:token], kind: l[:kind], factory: r[:factory], locker: l[:kind] == "single" ? a[:locker] : a[:multi_locker],
            deployer: rec[:deployer], creator_fee_recipient: rec[:creator_fee_recipient], launch_config_id: l[:config_id],
            pool_fee: rec[:pool_fee], tick_spacing: rec[:tick_spacing], base_fee_bps: rec[:base_fee_bps], creator_tax_bps: rec[:creator_tax_bps],
            protocol_fee_share_bps: rec[:protocol_fee_share_bps], protocol_fee_recipient: rec[:protocol_fee_recipient],
            name: r[:name], symbol: r[:symbol], decimals: r[:decimals], logo: r[:info]&.dig(1), description: r[:info]&.dig(2), socials:,
            supply: r[:supply], launched_at: ts[l[:block]] || rec[:launched_at], launch_block: l[:block], launch_tx: l[:tx],
            via_mirror: tagged[l[:tx]] || false
          )
          r[:markets].each_with_index do |m, i|
            pair = m[:pair_token]
            Market.create!(
              chain_id: chain.id, launch:, token: l[:token], idx: i, pool_id: l[:pool_ids][i], pair_token: pair,
              quote_symbol: r[:metas][i][:symbol], quote_decimals: r[:metas][i][:decimals], token_is_c0: l[:token].to_i(16) < pair.to_i(16),
              position_id: m[:position_id], phantom_quote: m[:phantom_quote], tick_lower: m[:tick_lower], tick_upper: m[:tick_upper],
              token_amount: l[:token_amounts][i] || 0
            )
          end
        end
      end
    end

    def supply_for(factory, config_id)
      @config_supply[[factory, config_id]] ||= rpc.call(factory, "getLaunchConfig(uint256)", config_id, returns: [Events::LAUNCH_CONFIG]).first.first
    end

    # ---------- quotes ----------
    def reference?(addr)
      addr = addr.downcase
      addr == Chains::ZERO || addr == chain.reference[:address].downcase || addr == chain.reference[:wrapped].downcase
    end

    def quote_meta(pair)
      return { symbol: chain.reference[:symbol], decimals: 18 } if pair == Chains::ZERO
      q = QuoteAsset.find_by(chain_id: chain.id, pair_token: pair)
      return { symbol: q.symbol, decimals: q.decimals } if q
      symbol = (rpc.call(pair, "symbol()", returns: ["string"]).first rescue "?")
      decimals = (rpc.call(pair, "decimals()", returns: ["uint8"]).first rescue 18)
      QuoteAsset.upsert({ chain_id: chain.id, pair_token: pair, symbol:, decimals: }, unique_by: %i[chain_id pair_token])
      price_quote(pair, decimals)
      { symbol:, decimals: }
    end

    def price_quote(pair, decimals)
      return if reference?(pair) || Launch.exists?(chain_id: chain.id, token: pair)
      # one whole unit of the reference asset: 1e18 for ETH/BNB, but 1e6 on Arc, whose reference is 6-decimal USDC
      one = 10**chain.reference[:decimals]
      raw = rpc.call(chain.addr(:quote_pricer), "priceEthAmountInQuote(address,uint256)", pair, one, returns: ["uint256"]).first
      per_eth = raw.to_f / 10**decimals
      QuoteAsset.where(chain_id: chain.id, pair_token: pair).update_all(eth_per_unit: per_eth.positive? ? 1 / per_eth : 0, priced_at: Time.current)
    rescue Rpc::Error
      nil # not priceable right now
    end

    def refresh_quotes
      usdg = chain.addr(:usdg)
      unless QuoteAsset.exists?(chain_id: chain.id, pair_token: usdg)
        dec = (rpc.call(usdg, "decimals()", returns: ["uint8"]).first rescue 6)
        sym = (rpc.call(usdg, "symbol()", returns: ["string"]).first rescue "USD")
        QuoteAsset.upsert({ chain_id: chain.id, pair_token: usdg, symbol: sym, decimals: dec }, unique_by: %i[chain_id pair_token])
      end
      rows = QuoteAsset.where(chain_id: chain.id).pluck(:pair_token, :decimals)
      rpc.pmap(rows, threads: 4) { |pair, dec| price_quote(pair, dec) }
      state.update!(quotes_refreshed_at: Time.current)
    end

    # ETH (reference asset) per whole unit of a quote asset
    def quote_eth(pair, depth = 0)
      return 1.0 if reference?(pair)
      return Pricing.new(chain).token_price_eth(pair, depth + 1) if depth < 3 && Launch.exists?(chain_id: chain.id, token: pair)
      QuoteAsset.where(chain_id: chain.id, pair_token: pair).pick(:eth_per_unit) || 0.0
    end

    # raw quote units per whole token, with 18 fractional digits: a 6-decimal quote (USDC, USDG) against a cheap token
    # is only a few raw units per token, so an integer would keep one or two significant digits
    def price_x18(sqrt, c0)
      return 0 if sqrt.zero?

      num, den = c0 ? [sqrt * sqrt * WAD, Q192] : [Q192 * WAD, sqrt * sqrt]
      BigDecimal("#{num * WAD / den}e-18")
    end

    # ---------- timestamps: exact every ts_granularity blocks, linear in between ----------
    def timestamps(blocks, cap)
      g = chain.ts_granularity
      bounds = ->(b) { lo = b - (b % g); [lo, [lo + g, cap].min] }
      samples = blocks.flat_map { bounds.(_1) }.uniq
      missing = samples - @ts_cache.keys
      if missing.any?
        BlockTimestamp.where(chain_id: chain.id, number: missing).pluck(:number, :ts).each { |n, t| @ts_cache[n] = t }
        missing -= @ts_cache.keys
        fetched = rpc.pmap(missing, threads: 8) { |n| [n, rpc.block_ts(n)] }
        if fetched.any?
          BlockTimestamp.insert_all(fetched.map { |n, t| { chain_id: chain.id, number: n, ts: t } }, unique_by: %i[chain_id number])
          fetched.each { |n, t| @ts_cache[n] = t }
        end
      end
      @ts_cache.shift while @ts_cache.size > 200_000
      blocks.to_h do |b|
        lo, hi = bounds.(b)
        tl, th = @ts_cache.fetch(lo), @ts_cache.fetch(hi)
        [b, hi == lo ? tl : (tl + (th - tl) * (b - lo).fdiv(hi - lo)).round]
      end
    end

    def exact_ts(block)
      @ts_cache[block] ||= BlockTimestamp.where(chain_id: chain.id, number: block).pick(:ts) || rpc.block_ts(block).tap do |t|
        BlockTimestamp.insert_all([{ chain_id: chain.id, number: block, ts: t }], unique_by: %i[chain_id number])
      end
    end

    # one-off repair for indexes built before launch times were exact
    def fix_launch_times
      launches = Launch.where(chain_id: chain.id).pluck(:id, :launch_block)
      exact = rpc.pmap(launches.map(&:last).uniq, threads: 8) { |b| [b, rpc.block_ts(b)] }.to_h
      launches.each { |id, b| Launch.where(id:).update_all(launched_at: exact[b]) }
      launches.size
    end

    # ---------- traders (tx.from) ----------
    def fill_traders(limit: 64, hashes: nil)
      hashes ||= Trade.where(chain_id: chain.id, trader: nil).group(:tx_hash)
                      .order(Arel.sql("MAX(block_number) DESC")).limit(limit).pluck(:tx_hash) # newest first
      return 0 if hashes.empty?
      found = rpc.pmap(hashes.uniq, threads: 8) { |h| [h, (rpc.tx_from(h) rescue nil)] }
      found.each { |h, from| Trade.where(chain_id: chain.id, tx_hash: h).update_all(trader: from) if from }
      found.size
    end

    # ---------- logs, halving the range when the node says the result is too large ----------
    TOO_BIG = /exceeds? (the )?(limit|max)|more than \d+|query returned|too many (logs|results)|spans|block range|range (is )?too|response size|max results/i

    def logs_safe(from, to, **filter)
      rpc.get_logs(from:, to:, **filter)
    rescue Rpc::Error => e
      raise unless from < to && e.details =~ TOO_BIG && e.details !~ Rpc::RATE_LIMIT
      mid = (from + to) / 2
      logs_safe(from, mid, **filter) + logs_safe(mid + 1, to, **filter)
    end
  end
end
