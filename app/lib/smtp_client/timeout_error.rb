# frozen_string_literal: true

module SMTPClient
  # Raised when an outgoing SMTP operation exceeds one of the hard deadlines
  # configured under `smtp_client`.
  class TimeoutError < StandardError
  end
end
