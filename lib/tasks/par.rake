namespace :par do
  desc "Replay par's history in the foreground until the chain head (faster than the job loop for a first sync). CHAIN=4663"
  task backfill: :environment do
    chain = Par::Chains.get(ENV.fetch("CHAIN", Par::Chains.enabled_ids.first.to_s))
    conn = ActiveRecord::Base.connection
    key = 0x7061_7200 + chain.id # same advisory lock as SyncChainJob: never two syncs of one chain
    abort "another sync of chain #{chain.id} is running" unless conn.select_value("SELECT pg_try_advisory_lock(#{key})")
    $stdout.sync = true
    Rails.logger = ActiveSupport::Logger.new($stdout).tap { _1.formatter = proc { |_, t, _, msg| "#{t.strftime('%H:%M:%S')} #{msg}\n" } }
    ActiveRecord::Base.logger = nil
    ix = Par::Indexer.new(chain)
    begin
      loop do
        ix.run_until(Process.clock_gettime(Process::CLOCK_MONOTONIC) + 300)
        break unless ix.state.backfilling
      rescue StandardError => e
        warn "#{e.class}: #{e.message} — retrying in 10 s"
        sleep 10
      end
      puts "caught up at block #{ix.state.cursor_block}; filling remaining traders from tx.from"
      while ix.fill_traders(limit: 400).positive? do end
    ensure
      conn.select_value("SELECT pg_advisory_unlock(#{key})")
    end
  end
end
