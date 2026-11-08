class PagesController < ApplicationController
  ARCHIVED_DOCS = Rails.root.join("public/archive/docs.html")

  def docs = send_file(ARCHIVED_DOCS, type: "text/html; charset=utf-8", disposition: "inline")

  def config_json
    render json: { chains: Par::Chains.enabled.map(&:to_public_h), upload: ENV["PINATA_JWT"].present?,
                   ipfsGateway: ENV.fetch("PAR_IPFS_GATEWAY", "https://ipfs.io/ipfs/") }
  end
end
