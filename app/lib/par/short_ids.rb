module Par
  # par.family put "https://par.family/t/<16 hex>" (first 8 bytes of the launch salt) in each token's
  # website field, because the address is not known before the transaction. Map those ids back.
  module ShortIds
    PATTERN = %r{/t/(\h{16})\b}i

    def self.resolve(id, chain_ids: Chains.enabled_ids)
      Launch.where(chain_id: chain_ids).where("socials->>'website' ILIKE ?", "%/t/#{id}%").order(:launched_at).pick(:chain_id, :token)
    end
  end
end
