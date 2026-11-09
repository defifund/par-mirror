class TokenProfile < ApplicationRecord
  SOCIALS = %w[twitter telegram discord website farcaster].freeze

  before_validation :tidy
  validates :token, format: { with: /\A0x\h{40}\z/ }
  validates :description, length: { maximum: 1000 }
  validate :links
  after_commit { Par::LaunchRows.expire(chain_id) }

  # the deployer or the creator-fee recipient of the launch may edit
  def self.editor?(launch, address) = address.present? && [launch.deployer, launch.creator_fee_recipient].compact.map(&:downcase).include?(address.downcase)

  private

  def tidy
    self.token = token.to_s.downcase
    self.description = description.to_s.gsub(/[[:cntrl:]&&[^\n]]/, "").strip.presence
    self.logo = logo.to_s.strip.presence
    self.socials = SOCIALS.to_h { [_1, socials.to_h[_1].to_s.strip.presence] }.compact
  end

  def links
    errors.add(:logo, :image_link) if logo && !logo.match?(%r{\A(ipfs://|https://)\S+\z})
    socials.each { |k, v| errors.add(:base, :https_link, field: I18n.t("create.social.#{k}", default: k.capitalize)) unless v.start_with?("https://") }
  end
end
