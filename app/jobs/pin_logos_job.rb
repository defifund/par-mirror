# Keeps a copy of every ipfs:// token logo on the mirror's own node, so images survive the
# original team's Pinata account. Picks up new launches' logos too. Runs in short slices.
class PinLogosJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: "pin_logos", duration: 15.minutes

  SLICE = 4.minutes
  THREADS = 3

  def perform
    return unless Par::Ipfs.enabled?
    discover
    deadline = Time.now + SLICE
    queue = Queue.new
    IpfsPin.due.order(:attempts, :id).limit(400).each { queue << _1 }
    workers = THREADS.times.map do
      Thread.new do
        Rails.application.executor.wrap do
          while Time.now < deadline && (pin = (queue.pop(true) rescue nil))
            pin_one(pin)
          end
        end
      end
    end
    ActiveSupport::Dependencies.interlock.permit_concurrent_loads { workers.each(&:join) }
  end

  def discover
    cids = Launch.where("logo LIKE 'ipfs://%'").distinct.pluck(:logo).filter_map { Par::Ipfs.cid_of(_1) }.select { Par::Ipfs.cid?(_1) }
    known = IpfsPin.where(cid: cids).pluck(:cid).to_set
    rows = (cids.uniq - known.to_a).map { { cid: _1, status: "pending" } }
    IpfsPin.insert_all(rows, unique_by: :cid) if rows.any?
  end

  def pin_one(pin)
    if Par::Ipfs.pinned?(pin.cid)
      return pin.update!(status: "pinned", pinned_at: pin.pinned_at || Time.current, error: nil)
    end
    source, bytes = Par::Ipfs.import(pin.cid)
    pin.update!(status: "pinned", source:, bytes:, pinned_at: Time.current, error: nil, attempts: pin.attempts + 1)
  rescue StandardError => e
    pin.update!(status: "failed", error: e.message.truncate(250), attempts: pin.attempts + 1)
  end
end
