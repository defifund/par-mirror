class TokensController < ApplicationController
  def show
    @row = Par::LaunchRows.find(current_chain, params[:token]) or
      return render(:missing, status: :not_found)
    q = Par::Queries.new(current_chain)
    @trades = q.trades(token: @row[:token], limit: 50, fill: :later)
    @holders = q.holders(@row[:token], limit: 50)
    @ref_usd = Par::Pricing.new(current_chain).ref_usd
  end
end
