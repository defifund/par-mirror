class TokensController < ApplicationController
  def show
    @row = Par::LaunchRows.find(current_chain, params[:token]) or
      return render(:missing, status: :not_found)
    q = Par::Queries.new(current_chain)
    @trades = q.trades(token: @row[:token], limit: 50, fill: :later)
    @holders = q.holders(@row[:token], limit: 50)
    @ref_usd = Par::Pricing.new(current_chain).ref_usd
  end

  # /t/<16 hex>: the short link par.family wrote into each token's website field
  def short
    chain_id, token = Par::ShortIds.resolve(params[:id].downcase)
    return render(:missing, status: :not_found) unless token
    redirect_to token_path(chain: Par::Chains.get(chain_id).slug, token:), status: :moved_permanently
  end
end
