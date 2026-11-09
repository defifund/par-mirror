class ApplicationController < ActionController::Base
  allow_browser versions: :modern
  helper_method :current_chain, :chain_payload, :current_wallet
  around_action :switch_locale

  LOCALES = %w[en zh-CN zh-TW].freeze

  private

  def switch_locale(&) = I18n.with_locale(pick_locale, &)

  # the visitor's own choice (cookie, set by LocalesController), else the browser's languages
  def pick_locale
    return cookies[:locale] if LOCALES.include?(cookies[:locale])
    request.headers["Accept-Language"].to_s.downcase.split(",").each do |part|
      tag = part.split(";").first.to_s.strip
      return "zh-TW" if tag.match?(/\Azh-(tw|hk|mo|hant)/)
      return "zh-CN" if tag.start_with?("zh")
      return "en" if tag.start_with?("en")
    end
    "en"
  end

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
