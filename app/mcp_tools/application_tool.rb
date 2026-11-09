# frozen_string_literal: true

# Base class for the mirror's MCP tools, on top of the official `mcp` gem (modelcontextprotocol/ruby-sdk),
# following the same layout as Pickful and smarts.
#
# Subclasses implement `self.payload(**args)` and return a plain Hash; `call` wraps it as one JSON text block.
# Bad input comes back as `{ error: "..." }` (the agent can read and correct it) instead of a protocol error.
#
# Every tool is read-only: nothing here signs, sends or builds a transaction.
class ApplicationTool < MCP::Tool
  # what a token row is reduced to in lists (a full row is ~3.4 KB; get_token returns it whole)
  SUMMARY_KEYS = %i[chain chainId token name symbol kind feeMode quoteSymbol lastPriceUsd marketCapUsd totalVolumeUsd
                    recentVolumeUsd holders tradeCount createdAt lastTradeAt deployer viaMirror].freeze
  ADDRESS = /\A0x\h{40}\z/

  class << self
    def inherited(subclass)
      super
      subclass.annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)
    end

    # MCP SDK entry point; subclasses implement `payload` instead.
    def call(server_context: nil, **args)
      text_response(payload(**args))
    rescue Par::Trading::Error => e
      text_response(error: e.message)
    rescue Par::Rpc::Error => e
      text_response(error: "a public chain node did not answer (#{e.message}); try again in a minute")
    end

    def payload(**)
      raise NotImplementedError, "#{name} must implement self.payload(**args)"
    end

    def text_response(hash)
      return hash if hash.is_a?(MCP::Tool::Response)

      MCP::Tool::Response.new([ { type: "text", text: hash.to_json } ])
    end

    # --- schema helpers ---------------------------------------------------------------------------

    def chain_slugs = Par::Chains.enabled.map(&:slug)

    def chain_schema(optional: false)
      note = optional ? " Omit to cover every chain." : ""
      { type: "string", enum: chain_slugs, description: "Chain: #{Par::Chains.enabled.map { "#{_1.slug} = #{_1.name}" }.join(', ')}.#{note}" }
    end

    def address_schema(what) = { type: "string", pattern: "^0x[0-9a-fA-F]{40}$", description: what }

    def limit_schema(default, max) = { type: "integer", minimum: 1, maximum: max, description: "How many items (default #{default}, at most #{max})." }

    # --- input helpers (each returns an error Hash on bad input; callers short-circuit on Hash) -----

    def resolve_chain(slug)
      id = Par::Chains.id_for(slug.to_s)
      return { error: "unknown chain #{slug.inspect}; use one of #{chain_slugs.join(', ')}" } unless Par::Chains.enabled_ids.include?(id)

      Par::Chains.get(id)
    rescue ArgumentError
      { error: "unknown chain #{slug.inspect}; use one of #{chain_slugs.join(', ')}" }
    end

    # every enabled chain when slug is blank, else a one-element list (or the error Hash)
    def chains_for(slug)
      return Par::Chains.enabled if slug.blank?

      c = resolve_chain(slug)
      c.is_a?(Hash) ? c : [ c ]
    end

    def address(value, field)
      value.to_s.match?(ADDRESS) ? value.to_s.downcase : { error: "#{field} must be a 0x-prefixed 40-hex-digit address" }
    end

    def clamp(value, default, max) = (value.presence || default).to_i.clamp(1, max)

    # "0.015" with 18 decimals -> 15000000000000000; an error Hash for bad input
    def raw_amount(value, decimals, field)
      s = value.to_s.strip
      return { error: "#{field} must be a positive decimal number such as \"0.01\"" } unless s.match?(/\A\d+(\.\d+)?\z/)
      return { error: "#{field} has more than #{decimals} decimal places" } if s.split(".")[1].to_s.size > decimals

      raw = (BigDecimal(s) * 10**decimals).to_i
      raw.positive? ? raw : { error: "#{field} must be greater than zero" }
    end

    def display(raw, decimals) = (BigDecimal(raw) / 10**decimals).round([ decimals, 8 ].min).to_s("F").sub(/\.?0+\z/, "")

    # --- output helpers -----------------------------------------------------------------------------

    def site = "https://#{ENV.fetch('APP_HOST', 'par.defi.club')}"

    def token_url(row) = "#{site}/token/#{row[:chain]}/#{row[:token]}"

    def summary(row) = row.slice(*SUMMARY_KEYS).merge(url: token_url(row))

    def find_token(chain, token)
      Par::LaunchRows.find(chain, token) || { error: "#{token} is not a par token on #{chain.slug}" }
    end
  end
end
