module Par
  # Quotes and unsigned transactions for buying and selling a par token, the Ruby side of par-sdk's trade.ts
  # (INTEGRATION.md 7 and A7). Nothing here signs or sends: `build` returns { to, data, value } for the
  # caller's own wallet, `quote` simulates the same call with eth_call.
  #
  # Paths, as in the SDK:
  # - single-market launch: PairPadRouter. swapExactIn when the pool is quoted in the native reference itself,
  #   else buyWithEth / sellToEth through the pricer's route to the quote asset.
  # - multi-market launch: PairPadMultiRouter, one trade split equally over every market the reference can
  #   reach, the slippage floor on the total.
  # - Arc, whose reference is the USDC ERC-20: the *Reference entry points, paid through an allowance.
  class Trading
    class Error < StandardError; end

    KEY = "(address,address,uint24,int24,address)" # PoolKey
    HOP = "(#{KEY},bool)"                           # one step of the reference <-> quote route
    LEG = "(uint8,#{HOP}[],uint256)"                # one market's slice of a multi-market trade
    SIM = "0x000000000000000000000000000000000000dead" # stand-in wallet for buy quotes, its balance overridden
    MAX_UINT = (1 << 256) - 1
    REVERTS = {
      Abi.selector("SlippageExceeded(uint256,uint256)") => "SlippageExceeded",
      Abi.selector("RouteBroken(uint256)") => "RouteBroken",
      Abi.selector("RouteEndMismatch(address,address)") => "RouteEndMismatch"
    }.freeze

    Mkt = Struct.new(:index, :pair, :quote_symbol, :quote_decimals, :token_is_c0, :key, keyword_init: true)

    attr_reader :chain, :token, :launch, :markets

    def initialize(chain, token)
      @chain = chain
      @token = token.downcase
      @launch = Launch.find_by(chain_id: chain.id, token: @token) or raise Error, "#{token} is not a par token on #{chain.slug}"
      @markets = ::Market.where(chain_id: chain.id, token: @token).order(:idx).map { market(_1) }
      raise Error, "no market indexed for #{token}" if @markets.empty?
    end

    def ref = chain.reference
    def native? = ref[:native]
    def multi? = launch.kind == "multi"
    def router = multi? ? chain.addr(:multi_router) : chain.addr(:router)
    def reference?(addr) = [ ref[:address].downcase, ref[:wrapped].downcase ].include?(addr.downcase)

    # reference -> quote (buy) and quote -> reference (sell) hops per market; nil for a market the pricer has
    # no route to (it then only trades in its own quote asset)
    def routes = @routes ||= markets.map { self.class.route(chain, rpc, _1.pair) }

    # { buy: reference -> quote hops, sell: the reverse }; empty for the reference itself, nil without a route
    def self.route(chain, rpc, pair)
      return { buy: [], sell: [] } if [ chain.reference[:address].downcase, chain.reference[:wrapped].downcase ].include?(pair.downcase)

      hops, = rpc.call(chain.addr(:quote_pricer), "route(address)", pair, returns: [ "#{HOP}[]", "bool" ])
      hops.empty? ? nil : { buy: hops.reverse, sell: hops }
    end

    # equal slices of `amount` over `routes` (nil = unreachable), dust to the largest (par-sdk splitAmount/buildLegs)
    def self.legs(routes, amount, side, indexes = routes.each_index.to_a)
      reachable = indexes.each_index.select { routes[_1] }
      return [] if reachable.empty?

      parts = Array.new(reachable.size) { amount / reachable.size }
      parts[parts.index(parts.max)] += amount - parts.sum
      reachable.zip(parts).filter_map { |i, part| [ indexes[i], routes[i][side == "buy" ? :buy : :sell], part ] if part.positive? }
    end

    # The unsigned transaction. amount_in is raw units of the reference (buy) or of the token (sell).
    def build(side, amount_in, min_out, recipient)
      raise Error, "side must be buy or sell" unless %w[buy sell].include?(side)

      buy = side == "buy"
      if multi?
        legs = legs(amount_in, side)
        raise Error, "no market of this token is reachable from #{ref[:symbol]}" if legs.empty?

        fn, args =
          if native? then [ buy ? "buyWithEth" : "sellToEth", [ token, legs, min_out, recipient ] ]
          elsif buy then [ "buyWithReference", [ token, legs, amount_in, min_out, recipient ] ]
          else [ "sellToReference", [ token, legs, min_out, recipient ] ]
          end
        sig = fn == "buyWithReference" ? "#{fn}(address,#{LEG}[],uint256,uint256,address)" : "#{fn}(address,#{LEG}[],uint256,address)"
        return tx(router, Abi.calldata(sig, *args), buy && native? ? amount_in : 0)
      end

      m = markets.first
      route = routes.first or raise Error, "no #{ref[:symbol]} route to #{m.quote_symbol}; this pool trades in its quote asset only"
      direct = native? ? m.pair == Chains::ZERO : reference?(m.pair)
      raise Error, "this single-market pool, quoted in #{m.quote_symbol}, has no #{ref[:symbol]} path on #{chain.name}" if !native? && !direct

      if direct
        data = Abi.calldata("swapExactIn(#{KEY},bool,uint256,uint256,address)", m.key, buy ? !m.token_is_c0 : m.token_is_c0, amount_in, min_out, recipient)
      elsif buy
        data = Abi.calldata("buyWithEth(#{KEY},#{HOP}[],uint256,address)", m.key, route[:buy], min_out, recipient)
      else
        data = Abi.calldata("sellToEth(#{KEY},bool,uint256,#{HOP}[],uint256,address)", m.key, m.token_is_c0, amount_in, route[:sell], min_out, recipient)
      end
      tx(router, data, buy && native? ? amount_in : 0)
    end

    # What the trade returns right now (raw units of the output), simulated as `owner`. Sells override the
    # token's balance and allowance slots, so any wallet can be quoted. Buys override the native balance;
    # on Arc the router pulls USDC through an allowance that cannot be faked, so the owner must have approved.
    def quote(side, amount_in, owner)
      t = build(side, amount_in, 0, owner)
      overrides =
        if side == "sell"
          { token => { stateDiff: { balance_slot(owner) => word(amount_in), allowance_slot(owner, t[:to]) => word(MAX_UINT) } } }
        else
          native_in = native? ? amount_in : amount_in * 10**(18 - ref[:decimals])
          { owner => { balance: "0x" + (native_in * 2 + 10**18).to_s(16) } }
        end
      out = rpc.simulate(to: t[:to], data: t[:data], from: owner, value: t[:value], overrides:)
      out.to_s.delete_prefix("0x").then { _1.empty? ? 0 : _1[0, 64].to_i(16) }
    rescue Rpc::Error => e
      raise Error, revert_reason(e)
    end

    # the approval a trade needs first, or nil: the token for sells, USDC on Arc for buys, nothing for native buys
    def approval_needed(side, amount_in, owner)
      asset = side == "sell" ? token : (native? ? nil : ref[:address].downcase)
      return nil unless asset

      have = rpc.call(asset, "allowance(address,address)", owner, router, returns: [ "uint256" ]).first
      return nil if have >= amount_in

      { asset:, spender: router, amount: amount_in, current: have,
        tx: tx(asset, Abi.calldata("approve(address,uint256)", router, amount_in), 0) }
    end

    # what the wallet holds of the trade's input: the token for sells, the reference for buys (raw units)
    def input_balance(side, owner)
      if side == "sell" then rpc.call(token, "balanceOf(address)", owner, returns: [ "uint256" ]).first
      elsif native? then rpc.balance(owner)
      else rpc.call(ref[:address], "balanceOf(address)", owner, returns: [ "uint256" ]).first
      end
    end

    private

    def rpc = @rpc ||= Rpc.new(chain)

    def tx(to, data, value) = { to:, data:, value: }

    def market(m)
      pair = m.pair_token.downcase
      c0, c1 = m.token_is_c0 ? [ token, pair ] : [ pair, token ]
      key = [ c0, c1, launch.pool_fee, launch.tick_spacing, Chains::ZERO ]
      id = "0x" + Abi.keccak(Abi.hex_bytes(Abi.encode([ KEY ], [ key ])))
      raise Error, "pool key of market #{m.idx} does not hash to its pool id" unless id == m.pool_id.downcase

      Mkt.new(index: m.idx, pair:, quote_symbol: m.quote_symbol, quote_decimals: m.quote_decimals, token_is_c0: m.token_is_c0, key:)
    end

    def legs(amount, side) = self.class.legs(routes, amount, side, markets.map(&:index))

    # OpenZeppelin ERC20 layout of the launch token: _balances at slot 0, _allowances at slot 1
    def balance_slot(owner) = "0x" + Abi.keccak(Abi.hex_bytes(Abi.encode(%w[address uint256], [ owner, 0 ])))

    def allowance_slot(owner, spender)
      inner = "0x" + Abi.keccak(Abi.hex_bytes(Abi.encode(%w[address uint256], [ owner, 1 ])))
      "0x" + Abi.keccak(Abi.hex_bytes(Abi.encode(%w[address bytes32], [ spender, inner ])))
    end

    def word(n) = "0x" + n.to_s(16).rjust(64, "0")

    def revert_reason(e)
      data = e.data.to_s
      name = REVERTS[data[0, 10]]
      return "#{name} (the pool moved or the route is stale; quote again)" if name
      return "reverted: #{Abi.decode([ 'string' ], '0x' + data[10..]).first}" if data.start_with?("0x08c379a0")

      "simulation failed: #{e.details}"
    end
  end
end
