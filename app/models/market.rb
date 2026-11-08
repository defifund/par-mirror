class Market < ApplicationRecord
  belongs_to :launch
  def tokens_on_curve = token_amount.to_i - tokens_sold.to_i
end
