require "net/http"

module Par
  # The mirror's own IPFS node (a kubo accessory next to the app, see config/deploy.yml).
  #   PAR_IPFS_API              kubo RPC, private to the docker network   (e.g. http://par_mirror-ipfs:5001)
  #   PAR_IPFS_LOCAL_GATEWAY    kubo gateway, serves only what we pin    (e.g. http://par_mirror-ipfs:8080)
  # Old logos are copied as CAR files (the original blocks, so every CID stays the same) from the
  # gateways that still have them; today that is essentially only Pinata's public gateway.
  module Ipfs
    CID = /\A(?:Qm[1-9A-HJ-NP-Za-km-z]{44}|b[a-z2-7]{40,100})\z/
    SOURCES = %w[https://gateway.pinata.cloud https://ipfs.io https://dweb.link].freeze
    MAX_BYTES = 10.megabytes

    module_function

    def enabled? = api.present?
    def api = ENV["PAR_IPFS_API"].presence
    def local_gateway = ENV["PAR_IPFS_LOCAL_GATEWAY"].presence
    def cid?(s) = s.is_a?(String) && CID.match?(s)

    def cid_of(uri) = uri.to_s.start_with?("ipfs://") ? uri.delete_prefix("ipfs://").split(%r{[/?#]}).first.presence : nil

    # pin an uploaded file; returns its CID (v1, raw leaves: the bafkrei… form Pinata also gives)
    def add(io, filename)
      req = Net::HTTP::Post.new(URI("#{api}/api/v0/add?pin=true&cid-version=1&quieter=true"))
      req.set_form([["file", io, { filename: filename }]], "multipart/form-data")
      JSON.parse(rpc(req, read_timeout: 60).body.lines.last)["Hash"]
    end

    class RateLimited < StandardError; end

    # copy one CID into the node; returns [source, bytes]. First over the IPFS network itself
    # (bitswap from whoever still pins it, e.g. Pinata's nodes: no gateway, no rate limit), then
    # as a CAR from the public gateways. Raises RateLimited when the gateways are throttling us.
    def import(cid)
      errors = []
      begin
        req = Net::HTTP::Post.new(URI("#{api}/api/v0/pin/add?arg=#{cid}&recursive=true&progress=false&timeout=60s"))
        rpc(req, read_timeout: 75)
        return ["p2p", stat_size(cid)]
      rescue StandardError => e
        errors << "p2p: #{e.message.truncate(80)}"
      end
      limited = 0
      SOURCES.each do |src|
        car = fetch_car(src, cid)
        req = Net::HTTP::Post.new(URI("#{api}/api/v0/dag/import?pin-roots=true&stats=true"))
        req.set_form([["file", StringIO.new(car), { filename: "#{cid}.car" }]], "multipart/form-data")
        out = rpc(req, read_timeout: 60).body.lines.map { JSON.parse(_1) }
        root = out.find { _1["Root"] }&.dig("Root")
        raise "CAR root mismatch" unless root && root.dig("Cid", "/") == cid && root["PinErrorMsg"].blank?
        return [src.delete_prefix("https://"), car.bytesize]
      rescue StandardError => e
        limited += 1 if e.message.include?("429")
        errors << "#{src.delete_prefix('https://')}: #{e.message.truncate(80)}"
      end
      raise RateLimited, errors.join("; ") if limited.positive?
      raise errors.join("; ")
    end

    def stat_size(cid)
      req = Net::HTTP::Post.new(URI("#{api}/api/v0/dag/stat?arg=#{cid}&progress=false"))
      JSON.parse(rpc(req, read_timeout: 30).body.lines.last)["TotalSize"]
    rescue StandardError
      nil
    end

    # the pinned blocks as a CAR file (restorable with dag/import, same CID)
    def export_car(cid)
      req = Net::HTTP::Post.new(URI("#{api}/api/v0/dag/export?arg=#{cid}&progress=false"))
      rpc(req, read_timeout: 60).body
    end

    def pinned?(cid)
      req = Net::HTTP::Post.new(URI("#{api}/api/v0/pin/ls?arg=#{cid}&type=recursive&quiet=true"))
      rpc(req, read_timeout: 10, raise_on_error: false).is_a?(Net::HTTPSuccess)
    end

    def fetch_car(src, cid)
      uri = URI("#{src}/ipfs/#{cid}?format=car")
      4.times do
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 40) do |h|
          h.get(uri.request_uri, "accept" => "application/vnd.ipld.car", "user-agent" => "par-community-mirror")
        end
        if res.is_a?(Net::HTTPRedirection) && res["location"]
          uri = URI.join(uri.to_s, res["location"])
          next
        end
        raise "HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)
        raise "not a CAR (#{res.content_type})" unless res.content_type.to_s.include?("ipld.car")
        raise "too large" if res.body.bytesize > MAX_BYTES
        return res.body
      end
      raise "too many redirects"
    end

    # GET a pinned file from the local gateway (no network fetches there); nil when we don't have it
    def local_get(cid, path = nil)
      return nil unless local_gateway
      uri = URI("#{local_gateway}/ipfs/#{cid}#{"/#{path}" if path.present?}")
      res = Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 10) { _1.get(uri.request_uri) }
      res.is_a?(Net::HTTPSuccess) && res.body.bytesize <= MAX_BYTES ? res : nil
    rescue StandardError
      nil
    end

    def rpc(req, read_timeout:, raise_on_error: true)
      uri = req.uri
      res = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout:) { _1.request(req) }
      raise "kubo #{res.code}: #{res.body.to_s.truncate(120)}" if raise_on_error && !res.is_a?(Net::HTTPSuccess)
      res
    end
  end
end
