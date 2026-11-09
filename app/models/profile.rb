class Profile < ApplicationRecord
  SOCIALS = %w[twitter telegram website farcaster].freeze
  RESERVED = /\b(par(\.family)?|official|admin|team|support|moderator|mod)\b/i

  before_validation :tidy
  validates :address, format: { with: /\A0x\h{40}\z/ }
  validates :name, length: { maximum: 32 }
  validates :bio, length: { maximum: 280 }
  validate :sane

  # address => name for everything shown on a page; small table, cached briefly
  def self.names = Rails.cache.fetch("profiles/names", expires_in: 1.minute) { where.not(name: [nil, ""]).pluck(:address, :name).to_h }
  after_commit { Rails.cache.delete("profiles/names") }

  private

  def tidy
    self.address = address.to_s.downcase
    self.name = name.to_s.gsub(/[[:cntrl:]​-‏‪-‮⁦-⁩]/, "").squish.presence
    self.bio = bio.to_s.gsub(/[[:cntrl:]&&[^\n]]/, "").strip.presence
    self.avatar = avatar.to_s.strip.presence
    self.socials = SOCIALS.to_h { [_1, socials.to_h[_1].to_s.strip.presence] }.compact
  end

  def sane
    errors.add(:name, "can't look like the original team or the site") if name&.match?(RESERVED)
    errors.add(:name, "can't be an address") if name&.match?(/0x\h{6,}/i)
    errors.add(:avatar, "must be an ipfs:// or https:// link") if avatar && !avatar.match?(%r{\A(ipfs://|https://)\S+\z})
    socials.each { |k, v| errors.add(:base, "#{k} must be an https:// link") if %w[website farcaster].include?(k) && !v.start_with?("https://") }
  end
end
