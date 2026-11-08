module Par
  # Second, independent pass over the few fee-vault contracts:
  #   PairPadDisperseV2 Dispersed / Paid -> distributions + rewards (holder payouts, ETH and ERC-20)
  #   PairPadDisperse v1 Dispersed       -> distributions; per-wallet amounts from the tx's token Transfer logs
  #   PairPadFloorVault WallMoved        -> floor_walls
  # It follows sync_states.extras_cursor and never runs ahead of the main cursor, so every launch it sees is known.
  # Only three addresses per query, so it catches up quickly even when the main replay is long done.
  class Extras
    attr_reader :chain, :ix

    def initialize(chain, indexer = Indexer.new(chain))
      @chain = chain
      @ix = indexer
    end

    def rpc = ix.rpc
    def state = ix.state

    def contracts
      @contracts ||= { v2: chain.addresses[:disperse], v1: chain.addresses[:disperse_v1], floor: chain.addresses[:floor_vault] }
                     .compact.transform_values(&:downcase).reject { |_, a| a == Chains::ZERO }
    end

    def cursor = state.extras_cursor || (chain.deploy_block - 1)
    def behind? = cursor < state.cursor_block

    def run_until(deadline)
      done = 0
      while cursor < state.cursor_block && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        from = cursor + 1
        to = [from + chain.log_span - 1, state.cursor_block].min
        n = process_range(from, to)
        done += 1
        Rails.logger.info("[par #{chain.slug}] extras #{from}-#{to} +#{n} rows") if n.positive?
      end
      done
    end

    def process_range(from, to)
      logs = contracts.any? ? ix.logs_safe(from, to, address: contracts.values) : []
      tokens = Launch.where(chain_id: chain.id).pluck(:token).to_set
      dist, rew, walls = [], [], []

      logs.each do |l|
        addr = l["address"].downcase
        t0 = l["topics"][0]
        base = { chain_id: chain.id, block_number: l["blockNumber"].to_i(16), log_index: l["logIndex"].to_i(16), tx_hash: l["transactionHash"] }
        if addr == contracts[:v2] && t0 == Events::DISPERSED.topic0
          e = Abi.decode_log(Events::DISPERSED, l)
          next unless tokens.include?(e[:launch])
          dist << base.merge(token: e[:launch], asset: e[:asset], sender: e[:sender], round: e[:round], total: e[:total], recipients: e[:recipients], version: 2)
        elsif addr == contracts[:v2] && t0 == Events::PAID.topic0
          e = Abi.decode_log(Events::PAID, l)
          next unless tokens.include?(e[:launch])
          rew << base.merge(token: e[:launch], asset: e[:asset], owner: e[:to], amount: e[:amount])
        elsif addr == contracts[:v1] && t0 == Events::DISPERSED_V1.topic0
          e = Abi.decode_log(Events::DISPERSED_V1, l)
          next unless tokens.include?(e[:token])
          dist << base.merge(token: e[:token], asset: e[:token], sender: e[:sender], round: e[:round], total: e[:total], recipients: e[:recipients], version: 1)
          rew.concat(v1_payouts(base[:tx_hash], e[:token], e[:sender]))
        elsif addr == contracts[:floor] && t0 == Events::WALL_MOVED.topic0
          e = Abi.decode_log(Events::WALL_MOVED, l)
          walls << base.merge(token: e[:token], quote: e[:quote], tick_lower: e[:tickLower], tick_upper: e[:tickUpper],
                              liquidity: e[:liquidity], quote_in_wall: e[:quoteInWall], circulating: e[:circulating])
        end
      end

      rows = dist + rew + walls
      ts = rows.any? ? ix.timestamps(rows.map { _1[:block_number] }.uniq, to) : {}
      rows.each { _1[:ts] = ts[_1[:block_number]] }

      ActiveRecord::Base.transaction do
        Distribution.insert_all(dist, unique_by: %i[chain_id block_number log_index]) if dist.any?
        Reward.insert_all(rew, unique_by: %i[chain_id block_number log_index]) if rew.any?
        FloorWall.insert_all(walls, unique_by: %i[chain_id block_number log_index]) if walls.any?
        state.update!(extras_cursor: to)
      end
      rows.size
    end

    # v1 pulled the token from the distributor with transferFrom, one Transfer per holder
    def v1_payouts(tx_hash, token, sender)
      receipt = rpc.request("eth_getTransactionReceipt", [tx_hash])
      receipt["logs"].filter_map do |l|
        next unless l["address"].downcase == token && l["topics"][0] == Events::TRANSFER.topic0
        e = Abi.decode_log(Events::TRANSFER, l)
        next unless e[:from] == sender
        { chain_id: chain.id, block_number: l["blockNumber"].to_i(16), log_index: l["logIndex"].to_i(16), tx_hash:,
          token:, asset: token, owner: e[:to], amount: e[:value] }
      end
    end
  end
end
