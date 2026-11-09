require "net/http"
require "openssl"

module Par
  # Minimal S3 client for Cloudflare R2 (SigV4, path-style), enough to back up and restore pins.
  #   R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET (default par-mirror-ipfs)
  # Use a token scoped to this one bucket (Object Read & Write).
  module R2
    module_function

    def enabled? = %w[R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY].all? { ENV[_1].present? }
    def bucket = ENV.fetch("R2_BUCKET", "par-mirror-ipfs")
    def host = "#{ENV.fetch('R2_ACCOUNT_ID')}.r2.cloudflarestorage.com"

    def put(key, body, content_type: "application/octet-stream")
      res = request("PUT", key, body:, headers: { "content-type" => content_type })
      raise "r2 PUT #{key}: HTTP #{res.code} #{res.body.to_s[0, 200]}" unless res.is_a?(Net::HTTPSuccess)
      true
    end

    def exists?(key) = request("HEAD", key).is_a?(Net::HTTPSuccess)

    def get(key)
      res = request("GET", key)
      res.is_a?(Net::HTTPSuccess) ? res.body : nil
    end

    def request(method, key, body: "", headers: {})
      body = body.to_s.b
      path = "/#{bucket}/#{key.split('/').map { URI.encode_www_form_component(_1).gsub('+', '%20') }.join('/')}"
      now = Time.now.utc
      amz_date = now.strftime("%Y%m%dT%H%M%SZ")
      date = now.strftime("%Y%m%d")
      payload_hash = OpenSSL::Digest::SHA256.hexdigest(body)
      hdrs = headers.transform_keys(&:downcase).merge("host" => host, "x-amz-date" => amz_date, "x-amz-content-sha256" => payload_hash)
      signed = hdrs.keys.sort
      canonical = [method, path, "", signed.map { "#{_1}:#{hdrs[_1].to_s.strip}\n" }.join, signed.join(";"), payload_hash].join("\n")
      scope = "#{date}/auto/s3/aws4_request"
      to_sign = ["AWS4-HMAC-SHA256", amz_date, scope, OpenSSL::Digest::SHA256.hexdigest(canonical)].join("\n")
      k = ["auto", "s3", "aws4_request"].reduce(hmac("AWS4#{ENV.fetch('R2_SECRET_ACCESS_KEY')}", date)) { |key_, part| hmac(key_, part) }
      sig = OpenSSL::HMAC.hexdigest("SHA256", k, to_sign)
      hdrs["authorization"] = "AWS4-HMAC-SHA256 Credential=#{ENV.fetch('R2_ACCESS_KEY_ID')}/#{scope}, SignedHeaders=#{signed.join(';')}, Signature=#{sig}"
      req = Net::HTTPGenericRequest.new(method, method == "PUT", method != "HEAD", path, hdrs.except("host"))
      Net::HTTP.start(host, 443, use_ssl: true, open_timeout: 10, read_timeout: 60) { _1.request(req, method == "PUT" ? body : nil) }
    end

    def hmac(key, data) = OpenSSL::HMAC.digest("SHA256", key, data)
  end
end
