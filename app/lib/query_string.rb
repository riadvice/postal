# frozen_string_literal: true

class QueryString

  RECOGNIZED_KEYS = %w[to from subject status tag spam held threat token msgid id before after order].freeze

  STATUSES = %w[Pending Sent Held SoftFail HardFail Bounced Error Processed].freeze

  def initialize(string)
    @string = string.strip + " "
  end

  def [](value)
    hash[value.to_s]
  end

  delegate :empty?, to: :hash

  # Whether the key was given at all, even with a blank value.
  def key?(key)
    hash.key?(key.to_s)
  end

  # Returns any keys that were parsed from the query string but aren't
  # understood by the search UI/controller, so callers can warn the user
  # about a likely typo instead of silently ignoring it.
  def unrecognized_keys
    hash.keys - RECOGNIZED_KEYS
  end

  def hash
    @hash ||= @string.scan(/([a-z]+):\s*(?:(\d{2,4}-\d{2}-\d{2}\s\d{2}:\d{2})|"(.*?)"|(.*?))(\s|\z)/).each_with_object({}) do |(key, date, string_with_spaces, value), hash|
      actual_value = date || string_with_spaces || value
      actual_value = nil if ["[blank]", ""].include?(actual_value)

      if hash.keys.include?(key.to_s)
        hash[key.to_s] = [hash[key.to_s]].flatten
        hash[key.to_s] << actual_value
      else
        hash[key.to_s] = actual_value
      end
    end
  end

end
