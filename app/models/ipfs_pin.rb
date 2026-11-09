class IpfsPin < ApplicationRecord
  scope :due, -> { where(status: "pending").or(where(status: "failed", attempts: ...IpfsPin::MAX_ATTEMPTS)) }
  MAX_ATTEMPTS = 6
end
