# frozen_string_literal: true

# Releases locks left behind by a dead or hung worker. Live workers renew theirs.
class RecoverQueuedMessageLocksTask < ApplicationScheduledTask

  # Not #retry_later: nothing was delivered, so recovering a lock must not
  # consume one of the message's delivery attempts or back off exponentially.
  RETRY_DELAY = 1.minute

  def call
    cutoff = Postal::Config.worker.queued_message_lock_timeout.seconds.ago
    recovered = QueuedMessage.where.not(locked_by: nil)
                             .where(locked_at: ...cutoff)
                             .update_all(locked_by: nil, locked_at: nil, retry_after: RETRY_DELAY.from_now)
    logger.info "recovered #{recovered} abandoned queued message locks" if recovered.positive?
  end

  def self.next_run_after
    1.minute.from_now
  end

end
