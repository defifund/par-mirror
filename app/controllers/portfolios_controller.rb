# The page itself is a shell; the wallet controller loads the turbo frame with ?owner= once connected.
class PortfoliosController < ApplicationController
  def show
    @owner = params[:owner].to_s.downcase.presence
    return unless @owner&.match?(/\A0x\h{40}\z/)
    @data = Par::Queries.new(current_chain).positions(@owner)
  end
end
