module Par
  # What each creator-fee mode needs to keep working now that the original team's services are gone.
  # Verified against the contracts (arc branch): HolderVault.harvest forwards to the team's distributor wallet;
  # BurnVault.buyback is operator-only (burnToken is open); FloorVault.rebalance is open to anyone.
  module FeeModes
    Mode = Data.define(:key, :title, :blurb, :launchable, :launch_note, :token_note, :severity)

    def self.all
      [
        Mode.new("creator", "To you", "Accrues to your fee wallet in the escrow. Claim any time.", true, nil, nil, nil),
        Mode.new("holders", "To holders", "Fees were paid out to holders every hour by the original team.", false,
                 "Disabled: the vault forwards fees to the original team's holder-rewards wallet, which ran the hourly payouts. Without the team, holders may never be paid.",
                 "Fees of this token go to holders through the original team's holder-rewards wallet, which ran the hourly payouts. With par.family offline those payouts may have stopped: fees keep accruing but may never reach holders.",
                 :err),
        Mode.new("burn", "Buyback & burn", "Fees were used to buy the token back in its own pool and burn it.", false,
                 "Disabled: only the vault's operator (the original team) can run the quote-side buyback, so that half of the fees would sit in the vault unused.",
                 "Buyback & burn: the token-side share is still burned (anyone can trigger it), but the quote-side buyback can only be run by the vault's operator, the original team. That half may sit in the vault unused.",
                 :warn),
        Mode.new("floor", "Floor mode", "A locked bid wall that can absorb the whole circulating supply; it only ever rises.", floor_enabled?,
                 "Disabled until this mirror's keeper runs: the wall only moves when someone calls rebalance (open to anyone, previously done by the team's keeper).",
                 floor_enabled? ? nil : "Floor mode: the bid wall only moves up when someone calls rebalance on the floor vault. Anyone can, but the original team's keeper no longer does, so the floor may lag behind.",
                 :warn)
      ]
    end

    # FloorVault.rebalance is permissionless; offer the mode once a keeper calls it (PAR_ALLOW_FLOOR_MODE=1)
    def self.floor_enabled? = ENV["PAR_ALLOW_FLOOR_MODE"] == "1"
    def self.[](key) = all.find { _1.key == key }
    def self.launchable_keys = all.select(&:launchable).map(&:key)
  end
end
