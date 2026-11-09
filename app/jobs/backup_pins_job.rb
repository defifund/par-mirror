# Copies every pinned image to Cloudflare R2 as a CAR file (car/<cid>.car), so the node's datastore
# can be rebuilt anywhere with `ipfs dag import`. Hourly, only what isn't backed up yet.
class BackupPinsJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: "backup_pins", duration: 30.minutes

  SLICE = 10.minutes

  def perform
    return unless Par::Ipfs.enabled? && Par::R2.enabled?
    deadline = Time.now + SLICE
    IpfsPin.where(status: "pinned", backed_up_at: nil).order(:id).limit(3000).each do |pin|
      break if Time.now > deadline
      car = Par::Ipfs.export_car(pin.cid)
      Par::R2.put("car/#{pin.cid}.car", car, content_type: "application/vnd.ipld.car")
      pin.update_columns(backed_up_at: Time.current)
    rescue StandardError => e
      Rails.logger.warn("[backup_pins] #{pin.cid}: #{e.message}")
    end
  end
end
