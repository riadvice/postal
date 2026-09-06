# frozen_string_literal: true

# Releases locks left behind by a dead or hung worker. Live workers renew theirs.
class RecoverQueuedMessageLocksTask < ApplicationScheduledTask

  def call
    cutoff = Postal::Config.worker.queued_message_lock_timeout.seconds.ago
    recovered = 0
    QueuedMessage.where.not(locked_by: nil).where(locked_at: ...cutoff).find_each do |message|
      message.retry_later
      recovered += 1
    end
    logger.info "recovered #{recovered} abandoned queued message locks" if recovered.positive?
  end

  def self.next_run_after
    1.minute.from_now
  end

end
