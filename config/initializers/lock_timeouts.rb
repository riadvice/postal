# frozen_string_literal: true

smtp = Postal::Config.smtp_client
minimum = smtp.start_timeout + smtp.transaction_timeout + 300
if Postal::Config.worker.queued_message_lock_timeout < minimum
  raise "worker.queued_message_lock_timeout must be greater than smtp_client.start_timeout + smtp_client.transaction_timeout + 300 (#{minimum}s) or a message can be delivered twice"
end
