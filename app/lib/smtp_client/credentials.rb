# frozen_string_literal: true

module SMTPClient
  # Credentials used to authenticate against an SMTP relay.
  class Credentials

    attr_reader :username
    attr_reader :password
    attr_reader :auth_type

    # @param username [String]
    # @param password [String]
    # @param auth_type [String, Symbol] one of the mechanisms supported by Net::SMTP
    def initialize(username, password, auth_type: nil)
      @username = username
      @password = password
      @auth_type = (auth_type.presence || :login).to_s.downcase.to_sym
    end

    # Never expose the password when the object is logged or inspected
    def inspect
      "#<#{self.class.name} username=#{@username.inspect} auth_type=#{@auth_type.inspect}>"
    end
    alias to_s inspect

  end
end
