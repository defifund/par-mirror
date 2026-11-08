module Par
  # Launches made through this mirror end their CREATE2 salt with these 8 bytes (ASCII "PARMIRR1").
  # The first 24 bytes stay random; the first 8 are what the original site used for /t/<id> links,
  # so they must not be fixed. The salt only lives in the launch transaction's input, never in events.
  module MirrorTag
    HEX = "5041524d49525231".freeze # "PARMIRR1"

    # true when a launch tx's calldata carries a TokenParams salt ending in the tag (a salt is a
    # 32-byte word, so the tag sits at the end of a word: offset ≡ 24 mod 32 after the selector)
    def self.in_calldata?(input)
      body = input.to_s.delete_prefix("0x").downcase[8..] or return false
      i = -1
      while (i = body.index(HEX, i + 1))
        return true if (i / 2) % 32 == 24
      end
      false
    end

    # only launches after the mirror went live can carry it; skip the extra lookup for older history
    def self.since_block(chain_id) = Integer(ENV.fetch("PAR_MIRROR_SINCE_#{chain_id}", chain_id == 4663 ? 109_000_000 : 0))
  end
end
