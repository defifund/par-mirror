class ApplicationController < ActionController::Base
  allow_browser versions: :modern
  helper_method :current_chain, :chain_payload

  private

  def current_chain
    @current_chain ||= begin
      id = Par::Chains.id_for(params[:chain].presence || Par::Chains.enabled_ids.first)
      raise ActionController::RoutingError, "unknown chain" unless Par::Chains.enabled_ids.include?(id)
      Par::Chains.get(id)
    end
  end

  # what the browser needs to build and send transactions (RPC, addresses, reference asset)
  def chain_payload = current_chain.to_public_h.to_json
end
