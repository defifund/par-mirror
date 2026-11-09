# frozen_string_literal: true

# POST /mcp: the mirror's public, read-only MCP server (Streamable HTTP, stateless), modelled on Pickful's PickfulMcpApp.
#
# - No auth: every tool reads public on-chain data the site already shows. quote_trade/build_trade only simulate and
#   return unsigned transactions; nothing here signs, holds keys or sends.
# - Stateless: each POST is one request/response, so it holds a web thread only for the query itself. That matters on a
#   box with 6 Puma threads (see /idx/:chain/events for what a held connection costs); listen streams are declined.
# - Per-IP rate limit, so an agent loop cannot crowd out the pages.
class ParMcpApp
  TOOLS = [
    ListChainsTool, SearchTokensTool, GetTokenTool, ResolveShortLinkTool,
    GetTradesTool, GetCandlesTool, GetHoldersTool, GetPositionsTool,
    GetFeesTool, GetClaimableTool, GetBurnsTool, GetFloorTool,
    GetHolderPayoutsTool, GetRewardsTool, GetBuybacksTool, GetStatsTool,
    QuoteTradeTool, BuildTradeTool, BuildLaunchTool, BuildClaimFeesTool
  ].freeze

  INSTRUCTIONS = <<~TEXT.squish
    Read-only data from the par community mirror: par is a token launchpad on Robinhood Chain, Base and Arc where every token
    trades from its first block in a permanently locked Uniswap pool. par.family is offline; this mirror re-indexes the same
    contracts. Start with list_chains, find tokens with search_tokens, then drill in. Amounts named *Eth or *Usd are decimals
    (Eth = the chain's reference asset, USDC on Arc); other amounts are raw integer strings in the asset's smallest unit.
    To trade, call quote_trade, then build_trade with its quoteId within 60 seconds: you get unsigned transactions
    (an exact approval when needed, then the trade with a minimum output) for your own wallet to sign and send.
    build_launch and build_claim_fees prepare a launch and a creator's fee claims the same way. This server
    never signs, holds keys or broadcasts. Nothing here is investment advice.
  TEXT

  REQUESTS_PER_MINUTE = ENV.fetch("PAR_MCP_RPM", 60).to_i

  def call(env)
    request = Rack::Request.new(env)
    return too_many_requests if throttled?(request)

    server = MCP::Server.new(name: "par-mirror", title: "par community mirror", version: "1.0.0",
                             website_url: "https://#{ENV.fetch('APP_HOST', 'par.defi.club')}", instructions: INSTRUCTIONS, tools: TOOLS)
    MCP::Server::Transports::StreamableHTTPTransport
      .new(server, stateless: true, serve_subscriptions_listen: false, allowed_hosts: allowed_hosts_for(request),
                   max_request_bytes: 64.kilobytes)
      .call(env)
  end

  private

  def throttled?(request)
    count = Rails.cache.increment("mcp/rpm/#{request.ip}/#{Time.now.to_i / 60}", 1, expires_in: 2.minutes)
    count.to_i > REQUESTS_PER_MINUTE
  end

  def too_many_requests
    [ 429, { "content-type" => "application/json", "retry-after" => "60" },
      [ { error: "rate_limited", message: "at most #{REQUESTS_PER_MINUTE} MCP requests per minute per IP" }.to_json ] ]
  end

  # Same rule as Pickful: follow Rails' own host allowlist (config.hosts), so the two never drift.
  # Empty config.hosts (development, test) admits the request host.
  def allowed_hosts_for(request)
    configured = Rails.application.config.hosts
    return [ request.host ] if configured.empty?

    configured.flat_map do |entry|
      case entry
      when String then [ entry ]
      when Regexp then entry.match?(request.host) ? [ request.host ] : []
      else []
      end
    end
  end
end
