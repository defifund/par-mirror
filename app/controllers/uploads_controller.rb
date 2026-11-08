# Pins a token image to IPFS through Pinata (optional; needs PINATA_JWT). Returns { uri: "ipfs://..." }.
class UploadsController < ApplicationController
  skip_forgery_protection only: :create

  def create
    jwt = ENV["PINATA_JWT"].presence or return render(json: { error: "uploads are not configured (set PINATA_JWT)" }, status: :not_implemented)
    file = params.require(:file)
    return render(json: { error: "image larger than 4 MB" }, status: :unprocessable_entity) if file.size > 4.megabytes
    return render(json: { error: "PNG, JPG, GIF or WebP only" }, status: :unprocessable_entity) unless %w[image/png image/jpeg image/gif image/webp].include?(file.content_type)

    uri = URI("https://api.pinata.cloud/pinning/pinFileToIPFS")
    req = Net::HTTP::Post.new(uri, "authorization" => "Bearer #{jwt}")
    req.set_form([["file", file.tempfile, { filename: file.original_filename.presence || "logo", content_type: file.content_type }]], "multipart/form-data")
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 60) { _1.request(req) }
    return render(json: { error: "pinata: #{res.code}" }, status: :bad_gateway) unless res.is_a?(Net::HTTPSuccess)
    render json: { uri: "ipfs://#{JSON.parse(res.body)['IpfsHash']}" }
  end
end
