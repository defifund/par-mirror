module Par
  # Unsigned launch transactions, the server side of the site's create form (create_controller.js):
  # one quote asset on Robinhood Chain/Base -> PairPadRouter.launchAndBuyWithEth; several, or any on Arc ->
  # PairPadMultiRouter (launchAndBuyWithEth, or launchAndBuyWithReference where the reference is USDC).
  #
  # Unlike the form, the optional opening buy gets a real minimum: the whole launch is simulated with eth_call
  # first (which also catches anything that would revert), and min = simulated tokens minus slippage. An ETH-quoted
  # opening buy cannot be front-run (the pool is created in the same transaction), but a route through other pools
  # to a different quote asset can. Nothing here signs or sends.
  class Launching
    class Error < StandardError; end

    TOKEN_PARAMS = "(string,string,string,string,(string,string,string,string,string),address,uint16,bytes32,bytes32)"
    SOCIALS = %w[twitter telegram discord website farcaster].freeze
    MAX_MARKETS = 5

    attr_reader :chain, :wallet

    def initialize(chain, wallet)
      @chain = chain
      @wallet = wallet.downcase
    end

    def ref = chain.reference
    def native? = ref[:native]

    # pairs: quote asset addresses (default: the reference). Returns the transaction(s) and what the simulation saw.
    def build(name:, symbol:, description: "", logo: "", socials: {}, fee_mode: "creator", creator_tax_bps: 0,
              pairs: nil, dev_buy: 0, slippage_bps: 100)
      fee_recipient = recipient(fee_mode) # input checks first, before any RPC
      pairs = (pairs.presence || [ native? ? Chains::ZERO : ref[:address].downcase ]).map(&:downcase).uniq
      raise Error, "at most #{MAX_MARKETS} quote assets" if pairs.size > MAX_MARKETS

      multi = pairs.size > 1 || !native? # Arc has only the multi-market stack
      factory = chain.addr(multi ? :multi_factory : :factory)
      router = chain.addr(multi ? :multi_router : :router)
      max_tax = rpc.call(chain.addr(:factory), "maxCreatorTaxBps()", returns: [ "uint256" ]).first
      raise Error, "creator_tax_bps must be 0..#{max_tax}" unless creator_tax_bps.between?(0, max_tax)
      raise Error, "this wallet may not launch on #{chain.name} right now (factory.canLaunch is false)" unless rpc.call(factory, "canLaunch(address)", wallet, returns: [ "bool" ]).first

      fee = rpc.call(factory, "launchFee()", returns: [ "uint256" ]).first
      params = [ name, symbol, logo.to_s, description.to_s, SOCIALS.map { socials[_1].to_s }, fee_recipient, creator_tax_bps, "0x" + "0" * 64, salt ]
      routes = pairs.map { Trading.route(chain, rpc, _1) }
      raise Error, "no #{ref[:symbol]} route to #{pairs[routes.index(nil)]} for the opening buy" if dev_buy.positive? && routes.any?(&:nil?) && !multi

      if dev_buy.positive? && !native?
        have = rpc.call(ref[:address], "allowance(address,address)", wallet, router, returns: [ "uint256" ]).first
        if have < dev_buy
          approval = { to: ref[:address].downcase, data: Abi.calldata("approve(address,uint256)", router, dev_buy), value: 0 }
          return { needs_approval_first: approval, launch_fee: fee }
        end
      end

      call = ->(min) { launch_tx(multi, router, params, pairs, routes, dev_buy, min, fee) }
      sim = simulate(call.(0), multi)
      min = dev_buy.positive? ? sim[:tokens_out] * (10_000 - slippage_bps) / 10_000 : 0
      { tx: call.(min), token: sim[:token], tokens_out: sim[:tokens_out], min_tokens_out: min, launch_fee: fee, multi:, router:, pairs: }
    end

    private

    def rpc = @rpc ||= Rpc.new(chain)

    def recipient(mode)
      raise Error, "fee_mode #{mode} cannot be launched on this mirror now (open: #{FeeModes.launchable_keys.join(', ')})" unless FeeModes.launchable_keys.include?(mode)

      { "creator" => wallet, "holders" => chain.addr(:holder_vault), "burn" => chain.addr(:burn_vault), "floor" => chain.addr(:floor_vault) }.fetch(mode)
    end

    # 24 random bytes + "PARMIRR1", so the launch is recognised as made through this mirror (MirrorTag)
    def salt = "0x" + SecureRandom.hex(24) + MirrorTag::HEX

    def launch_tx(multi, router, params, pairs, routes, buy, min, fee)
      if !multi
        r = routes.first || { buy: [] }
        data = Abi.calldata("launchAndBuyWithEth(#{TOKEN_PARAMS},uint256,address,#{Trading::HOP}[],uint256)", params, 0, pairs.first, r[:buy], min)
        return { to: router, data:, value: fee + buy }
      end

      legs = buy.positive? ? Trading.legs(routes, buy, "buy") : []
      raise Error, "none of the quote assets is reachable from #{ref[:symbol]} for the opening buy" if buy.positive? && legs.empty?

      if native?
        data = Abi.calldata("launchAndBuyWithEth(#{TOKEN_PARAMS},uint256,address[],#{Trading::LEG}[],uint256)", params, 0, pairs, legs, min)
        { to: router, data:, value: fee + buy }
      else
        data = Abi.calldata("launchAndBuyWithReference(#{TOKEN_PARAMS},uint256,address[],#{Trading::LEG}[],uint256,uint256)", params, 0, pairs, legs, buy, min)
        { to: router, data:, value: fee }
      end
    end

    def simulate(tx, multi)
      out = rpc.simulate(to: tx[:to], data: tx[:data], from: wallet, value: tx[:value],
                         overrides: { wallet => { balance: "0x" + (tx[:value] * 2 + 10**20).to_s(16) } })
      if multi
        token, tokens_out = Abi.decode(%w[address uint256], out)
      else
        token, _, tokens_out = Abi.decode(%w[address bytes32 uint256], out)
      end
      { token: token.downcase, tokens_out: }
    rescue Rpc::Error => e
      data = e.data.to_s
      reason = data.start_with?("0x08c379a0") ? Abi.decode([ "string" ], "0x" + data[10..]).first : e.details
      raise Error, "the launch would revert: #{reason}"
    end
  end
end
