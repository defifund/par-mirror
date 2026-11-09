# frozen_string_literal: true

class ResolveShortLinkTool < ApplicationTool
  tool_name "resolve_short_link"
  description "Turn a par short link (par.family/t/<16 hex> as written in token metadata, or the bare 16-hex id) into the chain and token address."
  input_schema(
    properties: { link: { type: "string", description: "A /t/<id> link or the 16-hex id." } },
    required: %w[link]
  )

  def self.payload(link:)
    id = link.to_s[%r{/t/(?:0x)?(\h{16})\b}i, 1] || link.to_s.delete_prefix("0x")[/\A\h{16}\z/]
    return { error: "expected a /t/<16 hex> link or a 16-hex id" } unless id

    chain_id, token = Par::ShortIds.resolve(id.downcase)
    return { error: "no par token carries the short id #{id}" } unless token

    c = Par::Chains.get(chain_id)
    { id: id.downcase, chain: c.slug, chainId: c.id, token:, url: "#{site}/token/#{c.slug}/#{token}" }
  end
end
