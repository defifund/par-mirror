# The page itself is a shell; the wallet controller loads ?owner= once a wallet is connected.
# One section per chain where the address holds, launched or earns something.
class PortfoliosController < ApplicationController
  def show
    @owner = params[:owner].to_s.downcase.presence
    return unless @owner&.match?(/\A0x\h{40}\z/)
    @sections = Par::Chains.enabled.filter_map do |c|
      data = Par::Queries.new(c).positions(@owner)
      [c, data] if data[:positions].any? || data[:launched].any?
    end
  end
end
