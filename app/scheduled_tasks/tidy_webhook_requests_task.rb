# frozen_string_literal: true

# Releases webhook request locks left behind by a worker that died mid-delivery
# so the request is retried instead of staying locked forever.
class TidyWebhookRequestsTask < ApplicationScheduledTask

  def call
    released = WebhookRequest.with_stale_lock.update_all(locked_by: nil, locked_at: nil)
    logger.info "released #{released} stale webhook request locks" if released.positive?
  end

  def self.next_run_after
    quarter_to_each_hour
  end

end
