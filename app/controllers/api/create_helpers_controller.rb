# Data for the create page: the "Stocks" quick pick and the "Any token" search.
module Api
  class CreateHelpersController < ActionController::API
    before_action :load_chain

    def stocks
      list = Par::Stocks.for(@chain)
      list ? render(json: list) : render(json: { items: [], error: "no stock list for this chain right now" }, status: (Par::Stocks::SOURCES[@chain.id] ? :bad_gateway : :not_found))
    end

    def tokens = render(json: { items: Par::TokenSearch.search(@chain, params[:q]) })

    private

    def load_chain
      id = Par::Chains.id_for(params[:chain].presence || Par::Chains.enabled_ids.first.to_s)
      return render(json: { error: "unknown chain" }, status: :not_found) unless Par::Chains.enabled_ids.include?(id)
      @chain = Par::Chains.get(id)
    rescue ArgumentError
      render json: { error: "unknown chain" }, status: :not_found
    end
  end
end
