# Public indexer API, compatible with the original api.par.family (par-sdk INTEGRATION.md A8).
# Mounted at /idx/:chain (chain id or slug), GET only, CORS open.
module Api
  class IndexerController < ActionController::API
    before_action :cors, :load_chain
    rescue_from(Par::Rpc::Error) { |e| render json: { error: e.message }, status: :bad_gateway }

    INTERVALS = { "1m" => 60, "5m" => 300, "15m" => 900, "1h" => 3600, "4h" => 14_400, "1d" => 86_400 }.freeze

    def health
      s = SyncState.find_by(chain_id: @chain.id)
      render json: { ok: s&.last_error.nil?, chainId: @chain.id, head: s&.head_block, indexed: s&.cursor_block,
                     lagBlocks: s && (s.head_block.to_i - s.cursor_block), backfilling: s&.backfilling, error: s&.last_error }
    end

    # GET /idx/:chain/pulse?since=<block>: what changed since a block, for pages that refresh themselves.
    # Cheap and briefly cacheable; browsers poll this instead of holding an /events stream open.
    def pulse
      cursor, head = SyncState.where(chain_id: @chain.id).pick(:cursor_block, :head_block)
      since = params[:since].to_i
      out = { chainId: @chain.id, cursor: cursor.to_i, head: head.to_i }
      if since.positive? && since < cursor.to_i
        from = [since, cursor - 20_000].max + 1
        out.merge!(Rails.cache.fetch(["idx/pulse", @chain.id, from, cursor], expires_in: 1.minute) do
          trades = Trade.where(chain_id: @chain.id, block_number: from..cursor)
          { tokens: trades.distinct.limit(500).pluck(:token), trades: trades.count,
            launches: Launch.where(chain_id: @chain.id, launch_block: from..cursor).count }
        end)
      end
      response.headers["Cache-Control"] = "public, max-age=2"
      render json: out
    end

    def launches = render(json: Par::LaunchRows.filter(rows, params).last)
    def count = render(json: { launched: Launch.where(chain_id: @chain.id).count })

    def launch
      r = Par::LaunchRows.find(@chain, params[:token])
      r ? render(json: r) : render(json: { error: "not a par token" }, status: :not_found)
    end

    def trades
      render json: Par::Queries.new(@chain).trades(token: params[:token], wallet: params[:wallet], limit: params[:limit])
    end

    def candles
      step = INTERVALS[params[:interval]] || 300
      render json: { candles: Par::Queries.new(@chain).candles(params[:token].to_s.downcase, step:, limit: (params[:limit].presence || 300).to_i.clamp(1, 1000),
                                                              before: params[:before].presence&.to_i, market: params[:market].presence&.to_i) }
    end

    def holders = render(json: Par::Queries.new(@chain).holders(params[:token].to_s.downcase, limit: (params[:limit].presence || 100).to_i.clamp(1, 500)))

    def positions
      return render(json: { error: "owner required" }, status: :bad_request) unless params[:owner].to_s.match?(/\A0x\h{40}\z/)
      render json: Par::Queries.new(@chain).positions(params[:owner].downcase)
    end

    def fees
      r = Par::LaunchRows.find(@chain, params[:token].to_s)
      return render(json: { error: "not a par token" }, status: :not_found) unless r
      render json: Par::Queries.new(@chain).fees(r)
    end

    def claimable
      return render(json: { error: "owner required" }, status: :bad_request) unless params[:owner].to_s.match?(/\A0x\h{40}\z/)
      render json: Par::Queries.new(@chain).claimable(params[:owner].downcase)
    end

    # burn-vault rounds of a "burn" launch (par-sdk FeeBurns)
    def burns
      token = params[:token].to_s.downcase
      vault = @chain.addr(:burn_vault)
      scope = Burn.where(chain_id: @chain.id, token:, from_addr: vault)
      limit = (params[:limit].presence || 200).to_i.clamp(1, 1000)
      render json: { token:, vault:, burns: scope.count, lastAt: scope.maximum(:ts), total: scope.sum(:amount).to_i.to_s,
                     items: scope.order(block_number: :desc, log_index: :desc).limit(limit)
                                 .map { { id: "#{_1.tx_hash}-#{_1.log_index}", amount: _1.amount.to_i.to_s, txHash: _1.tx_hash, timestamp: _1.ts } } }
    end

    def distributions
      return bad("token required") unless addr?(params[:token])
      render json: payouts.distributions(params[:token], limit: (params[:limit].presence || 200).to_i)
    end

    def rewards
      return bad("owner required") unless addr?(params[:owner])
      return bad("bad token") if params[:token].present? && !addr?(params[:token])
      render json: payouts.rewards(params[:owner], token: params[:token].presence, limit: (params[:limit].presence || 500).to_i)
    end

    def floor
      r = Par::LaunchRows.find(@chain, params[:token].to_s)
      return render(json: { error: "not a par token" }, status: :not_found) unless r
      render json: payouts.floor(r, quote: params[:quote].presence)
    end

    # short id from the token's website metadata (/t/<first 8 bytes of the launch salt>) -> token
    def resolve
      id = params[:id].to_s.downcase.delete_prefix("0x")
      return bad("id must be 16 hex") unless id.match?(/\A\h{16}\z/)
      token = Par::ShortIds.resolve(id, chain_ids: [@chain.id])&.last
      token ? render(json: { token:, chainId: @chain.id }) : render(json: { error: "unknown id" }, status: :not_found)
    end

    def buybacks
      return render(json: { error: "no $par on this chain" }, status: :not_found) if @chain.addr(:par) == Par::Chains::ZERO
      render json: Par::Queries.new(@chain).buybacks
    end

    def stats = render(json: Par::Queries.new(@chain).stats)

    def tokenlist
      render json: { name: "par launches (community mirror)", timestamp: Time.current.iso8601, version: { major: 1, minor: rows.size, patch: 0 },
                     tokens: rows.map { { chainId: _1[:chainId], address: _1[:token], name: _1[:name], symbol: _1[:symbol], decimals: _1[:decimals], logoURI: _1[:logoUrl], tags: ["par"] } } }
    end

    private

    def payouts = Par::Payouts.new(@chain)
    def addr?(v) = v.to_s.match?(/\A0x\h{40}\z/)
    def bad(msg) = render(json: { error: msg }, status: :bad_request)

    def rows = Par::LaunchRows.for(@chain)

    def load_chain
      id = Par::Chains.id_for(params[:chain].presence || Par::Chains.enabled_ids.first.to_s)
      return render(json: { error: "unknown chain" }, status: :not_found) unless Par::Chains.enabled_ids.include?(id)
      @chain = Par::Chains.get(id)
    rescue ArgumentError
      render json: { error: "unknown chain" }, status: :not_found
    end

    def cors
      response.set_header("access-control-allow-origin", "*")
      response.set_header("cache-control", "no-store")
    end
  end
end
