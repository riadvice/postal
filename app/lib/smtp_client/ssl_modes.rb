# frozen_string_literal: true

module SMTPClient
  module SSLModes

    AUTO = "Auto"
    STARTTLS = "STARTTLS"
    # Configuration and endpoints written against the historic misspelling
    LEGACY_STARTTLS = "STARTLS"
    TLS = "TLS"
    NONE = "None"

  end
end
