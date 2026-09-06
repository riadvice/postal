# frozen_string_literal: true

# Releases locks left behind by a dead or hung worker. Live workers renew theirs.
class RecoverQueuedMessageLocksTask < ApplicationScheduledTask

  def call
    cutoff = Postal::Config.worker.queued_message_lock_timeout.seconds.ago
    recovered = QueuedMessage.where.not(locked_by: nil).where(locked_at: ...cutoff).update_all(locked_by: nil, locked_at: nil)
    logger.info "recovered #{recovered} abandoned queued message locks" if recovered.positive?
  end

  def self.next_run_after
    1.minute.from_now
  end

end
