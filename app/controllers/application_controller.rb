class ApplicationController < ActionController::Base
  allow_browser versions: :modern
  helper_method :current_chain, :chain_payload, :current_wallet

  private

  def current_chain
    @current_chain ||= begin
      id = Par::Chains.id_for(params[:chain].presence || Par::Chains.enabled_ids.first)
      raise ActionController::RoutingError, "unknown chain" unless Par::Chains.enabled_ids.include?(id)
      Par::Chains.get(id)
    end
  end

  SESSION_TTL = 7.days

  # the address proven by a Sign-In with Ethereum signature (see AuthController), or nil
  def current_wallet
    w = session[:wallet]
    return nil unless w.is_a?(Hash) && w["address"].to_s.match?(/\A0x\h{40}\z/) && w["at"].to_i > SESSION_TTL.ago.to_i
    w["address"]
  end

  # what the browser needs to build and send transactions (RPC, addresses, reference asset)
  def chain_payload = current_chain.to_public_h.to_json
end
