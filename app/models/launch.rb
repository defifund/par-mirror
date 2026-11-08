class Launch < ApplicationRecord
  has_many :markets, -> { order(:idx) }, dependent: :destroy

  def chain = Par::Chains.get(chain_id)
  def to_param = token

  def fee_mode
    a = chain
    case creator_fee_recipient
    when a.addr(:holder_vault) then "holders"
    when a.addr(:burn_vault) then "burn"
    when a.addr(:floor_vault) then "floor"
    else "creator"
    end
  end

  def circulating = supply.to_i - burned.to_i
  def logo_url = Par::Pricing.http_url(logo)
end
