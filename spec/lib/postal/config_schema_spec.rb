# frozen_string_literal: true

require "rails_helper"
require "konfig/error"
require "konfig/sources/abstract"

module Postal

  RSpec.describe ConfigSchema do
    let(:source_class) do
      Class.new(Konfig::Sources::Abstract) do
        def initialize(values)
          super()
          @values = values
        end

        def get(path, attribute: nil)
          value = @values.dig(*path.map(&:to_s))
          raise Konfig::ValueNotPresentError if value.nil?

          value
        end
      end
    end

    def build_config(values)
      Konfig::Config.build(described_class, sources: [source_class.new(values)])
    end

    describe "postal.smtp_relays" do
      def relays(*urls)
        build_config("postal" => { "smtp_relays" => urls }).postal.smtp_relays.map(&:to_h)
      end

      it "parses a relay without credentials" do
        expect(relays("smtp://relay.example.com:587?ssl_mode=TLS")).to eq [
          { "host" => "relay.example.com", "port" => 587, "ssl_mode" => "TLS" },
        ]
      end

      it "defaults the port and SSL mode" do
        expect(relays("smtp://relay.example.com")).to eq [
          { "host" => "relay.example.com", "port" => 25, "ssl_mode" => "Auto" },
        ]
      end

      it "parses credentials with login as the default auth type" do
        expect(relays("smtp://relay-user:relay-pass@relay.example.com:587?ssl_mode=TLS")).to eq [
          { "host" => "relay.example.com", "port" => 587, "ssl_mode" => "TLS",
            "username" => "relay-user", "password" => "relay-pass", "auth_type" => "login" },
        ]
      end

      it "accepts an explicit auth type in any case" do
        expect(relays("smtp://relay-user:relay-pass@relay.example.com?auth_type=PLAIN").first).to include("auth_type" => "plain")
      end

      it "percent-decodes credentials and keeps a literal plus sign" do
        expect(relays("smtp://relay%40user:pa%24%24%3Aw+ord@relay.example.com").first).to include(
          "username" => "relay@user",
          "password" => "pa$$:w+ord"
        )
      end

      it "upgrades Auto to STARTTLS when credentials are given" do
        expect(relays("smtp://relay-user:relay-pass@relay.example.com").first).to include("ssl_mode" => "STARTTLS")
      end

      it "refuses to send credentials without encryption" do
        expect { relays("smtp://relay-user:relay-pass@relay.example.com?ssl_mode=None") }
          .to raise_error(ArgumentError, /has credentials but ssl_mode=None/)
      end

      it "rejects an unsupported auth type" do
        expect { relays("smtp://relay-user:relay-pass@relay.example.com?auth_type=xoauth2") }
          .to raise_error(ArgumentError, /auth_type for SMTP relay relay.example.com must be plain, login or cram_md5/)
      end
    end
  end

end
