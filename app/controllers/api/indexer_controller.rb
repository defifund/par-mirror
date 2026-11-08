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

    def burns
      render json: Burn.where(chain_id: @chain.id, token: params[:token].to_s.downcase).order(block_number: :desc).limit(500)
                       .map { { txHash: _1.tx_hash, timestamp: _1.ts, from: _1.from_addr, amount: _1.amount.to_i.to_s } }
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
