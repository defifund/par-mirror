module Par
  # Prices everything in the chain's reference asset (ETH on Robinhood Chain) and in USD via the
  # pricer's dollar anchor (USDG). Built once per request/cache window from a few bulk queries.
  class Pricing
    # our own /ipfs/ route: pinned copies from the mirror's node, else a redirect to a public gateway
    def self.ipfs_gateway = ENV["PAR_IPFS_GATEWAY"].presence || "/ipfs/"

    def self.http_url(uri)
      return nil if uri.blank?
      return uri.sub("ipfs://", ipfs_gateway) if uri.start_with?("ipfs://")
      uri =~ %r{\Ahttps?://} ? uri : nil
    end

    attr_reader :chain

    def initialize(chain)
      @chain = chain
      @markets = Market.where(chain_id: chain.id).pluck(:token, :pair_token, :quote_decimals, :last_price_x18, :tokens_sold)
                       .group_by(&:first)
      @quotes = QuoteAsset.where(chain_id: chain.id).pluck(:pair_token, :eth_per_unit).to_h
      @memo = {}
    end

    def reference?(addr)
      a = addr.downcase
      a == Chains::ZERO || a == chain.reference[:address].downcase || a == chain.reference[:wrapped].downcase
    end

    def quote_eth(pair, depth = 0)
      return 1.0 if reference?(pair)
      return token_price_eth(pair, depth + 1) if depth < 3 && @markets.key?(pair)
      @quotes[pair] || 0.0
    end

    # price of one whole token, from its deepest-traded market that can be valued
    def token_price_eth(token, depth = 0)
      @memo[[token, depth]] ||= begin
        ms = (@markets[token] || []).sort_by { -_5.to_i }
        ms.each do |_, pair, dec, px, _|
          p = px.to_f / 10**dec
          qe = quote_eth(pair, depth)
          break p * qe if p.positive? && qe.positive?
        end.then { _1.is_a?(Float) ? _1 : 0.0 }
      end
    end

    def ref_usd
      return 1.0 if chain.reference[:usd_is_one]
      e = quote_eth(chain.addr(:usdg))
      e.positive? ? 1 / e : 0.0
    end
  end
end
