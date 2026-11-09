module Par
  # What each creator-fee mode needs to keep working now that the original team's services are gone.
  # Verified against the contracts (arc branch): HolderVault.harvest forwards to the team's distributor wallet;
  # BurnVault.buyback is operator-only (burnToken is open); FloorVault.rebalance is open to anyone.
  module FeeModes
    Mode = Data.define(:key, :title, :blurb, :launchable, :launch_note, :token_note, :severity)

    # texts come from config/locales (fee_modes.*), in the visitor's language
    def self.all
      t = ->(k) { I18n.t("fee_modes.#{k}") }
      [
        Mode.new("creator", t.("creator.title"), t.("creator.blurb"), true, nil, nil, nil),
        Mode.new("holders", t.("holders.title"), t.("holders.blurb"), false, t.("holders.launch_note"), t.("holders.token_note"), :err),
        Mode.new("burn", t.("burn.title"), t.("burn.blurb"), false, t.("burn.launch_note"), t.("burn.token_note"), :warn),
        Mode.new("floor", t.("floor.title"), t.("floor.blurb"), floor_enabled?, t.("floor.launch_note"),
                 floor_enabled? ? nil : t.("floor.token_note"), :warn)
      ]
    end

    # FloorVault.rebalance is permissionless; offer the mode once a keeper calls it (PAR_ALLOW_FLOOR_MODE=1)
    def self.floor_enabled? = ENV["PAR_ALLOW_FLOOR_MODE"] == "1"
    def self.[](key) = all.find { _1.key == key }
    def self.launchable_keys = all.select(&:launchable).map(&:key)
  end
end
