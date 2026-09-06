# frozen_string_literal: true

module SMTPClient
  # Raised when an outgoing SMTP operation exceeds a hard deadline
  class TimeoutError < StandardError
  end
end
