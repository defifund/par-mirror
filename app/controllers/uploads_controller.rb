# Pins a token image to IPFS: on the mirror's own node when PAR_IPFS_API is set, else through
# Pinata when PINATA_JWT is set. Returns { uri: "ipfs://..." }.
class UploadsController < ApplicationController
  skip_forgery_protection only: :create
  rate_limit to: 20, within: 1.hour, only: :create, with: -> { render json: { error: "too many uploads, try again later" }, status: :too_many_requests }

  TYPES = { "image/png" => "\x89PNG".b, "image/jpeg" => "\xFF\xD8\xFF".b, "image/gif" => "GIF8".b, "image/webp" => "RIFF".b }.freeze

  def self.enabled? = Par::Ipfs.enabled? || ENV["PINATA_JWT"].present?

  def create
    return render(json: { error: "uploads are not configured on this mirror" }, status: :not_implemented) unless self.class.enabled?
    file = params.require(:file)
    return render(json: { error: "image larger than 4 MB" }, status: :unprocessable_entity) if file.size > 4.megabytes
    magic = TYPES[file.content_type]
    head = file.tempfile.read(12).to_s.b
    file.tempfile.rewind
    unless magic && head.start_with?(magic) && (file.content_type != "image/webp" || head[8, 4] == "WEBP")
      return render(json: { error: "PNG, JPG, GIF or WebP only" }, status: :unprocessable_entity)
    end

    cid = Par::Ipfs.enabled? ? local(file) : pinata(file)
    render json: { uri: "ipfs://#{cid}" }
  rescue StandardError => e
    Rails.logger.warn("[upload] #{e.class}: #{e.message}")
    render json: { error: "upload failed, try again" }, status: :bad_gateway
  end

  private

  def local(file)
    cid = Par::Ipfs.add(file.tempfile, file.original_filename.presence || "logo")
    IpfsPin.upsert({ cid:, status: "pinned", source: "upload", bytes: file.size, pinned_at: Time.current }, unique_by: :cid)
    cid
  end

  def pinata(file)
    uri = URI("https://api.pinata.cloud/pinning/pinFileToIPFS")
    req = Net::HTTP::Post.new(uri, "authorization" => "Bearer #{ENV['PINATA_JWT']}")
    req.set_form([["file", file.tempfile, { filename: file.original_filename.presence || "logo", content_type: file.content_type }]], "multipart/form-data")
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 60) { _1.request(req) }
    raise "pinata #{res.code}" unless res.is_a?(Net::HTTPSuccess)
    JSON.parse(res.body)["IpfsHash"]
  end
end
