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

      it "accepts cram_md5" do
        expect(relays("smtp://u:p@relay.example.com?auth_type=cram_md5").first).to include("auth_type" => "cram_md5")
      end

      it "ignores the auth type when there are no credentials" do
        expect(relays("smtp://relay.example.com?auth_type=xoauth2")).to eq [
          { "host" => "relay.example.com", "port" => 25, "ssl_mode" => "Auto" },
        ]
      end

      it "uses an empty password when only a username is given" do
        expect(relays("smtp://relay-user@relay.example.com").first).to include("username" => "relay-user", "password" => "")
      end

      it "reads several query parameters" do
        expect(relays("smtp://u:p@relay.example.com:2525?ssl_mode=TLS&auth_type=plain").first).to include(
          "port" => 2525, "ssl_mode" => "TLS", "auth_type" => "plain"
        )
      end

      it "uses the first value of a repeated query parameter" do
        expect(relays("smtp://relay.example.com?ssl_mode=TLS&ssl_mode=None").first).to include("ssl_mode" => "TLS")
      end

      it "parses several relays" do
        expect(relays("smtp://a.example.com", "smtp://b.example.com:587").map { |r| [r["host"], r["port"]] }).to eq [["a.example.com", 25], ["b.example.com", 587]]
      end

      it "parses an IP address host" do
        expect(relays("smtp://10.0.0.1:25").first).to include("host" => "10.0.0.1")
      end

      it "defaults to an empty array" do
        expect(build_config({}).postal.smtp_relays).to eq []
      end

      it "rejects a URL with a non-numeric port" do
        expect { relays("smtp://relay.example.com:smtp") }.to raise_error(URI::InvalidURIError)
      end

      it "rejects a URL containing spaces" do
        expect { relays("smtp://relay example.com") }.to raise_error(URI::InvalidURIError)
      end

      it "parses an IPv6 host" do
        expect(relays("smtp://[2001:db8::1]:2525").first).to include("host" => "2001:db8::1", "port" => 2525)
      end

      it "rejects a relay without a scheme" do
        expect { relays("relay.example.com:25") }.to raise_error(StandardError)
      end
    end

    describe "postal.trusted_proxies" do
      def proxies(*ips)
        build_config("postal" => { "trusted_proxies" => ips }).postal.trusted_proxies
      end

      it "parses IPv4 addresses" do
        expect(proxies("10.0.0.1")).to eq [IPAddr.new("10.0.0.1")]
      end

      it "parses IPv4 ranges" do
        expect(proxies("10.0.0.0/8").first).to include(IPAddr.new("10.255.255.255"))
      end

      it "parses IPv6 addresses and ranges" do
        expect(proxies("::1", "2001:db8::/32")).to eq [IPAddr.new("::1"), IPAddr.new("2001:db8::/32")]
      end

      it "rejects invalid addresses" do
        expect { proxies("300.0.0.1") }.to raise_error(IPAddr::InvalidAddressError)
        expect { proxies("not-an-ip") }.to raise_error(IPAddr::InvalidAddressError)
        expect { proxies("10.0.0.1; DROP") }.to raise_error(IPAddr::InvalidAddressError)
      end

      it "rejects an address with surrounding whitespace" do
        expect { proxies(" 10.0.0.1") }.to raise_error(IPAddr::InvalidAddressError)
      end

      it "defaults to an empty array" do
        expect(build_config({}).postal.trusted_proxies).to eq []
      end
    end

    describe "path substitution" do
      let(:config_root) { File.dirname(Postal.config_file_path) }

      it "substitutes the config file root in signing_key_path" do
        expect(build_config("postal" => { "signing_key_path" => "$config-file-root/signing.key" }).postal.signing_key_path).to eq "#{config_root}/signing.key"
      end

      it "substitutes the config file root in the TLS paths" do
        config = build_config("smtp_server" => { "tls_certificate_path" => "$config-file-root/smtp.cert", "tls_private_key_path" => "$config-file-root/smtp.key" })
        expect(config.smtp_server.tls_certificate_path).to eq "#{config_root}/smtp.cert"
        expect(config.smtp_server.tls_private_key_path).to eq "#{config_root}/smtp.key"
      end

      it "leaves absolute paths alone" do
        expect(build_config("postal" => { "signing_key_path" => "/etc/postal/key.pem" }).postal.signing_key_path).to eq "/etc/postal/key.pem"
      end
    end

    describe "environment variable parsing" do
      def env_config(env)
        Konfig::Config.build(described_class, sources: [Konfig::Sources::Environment.new(env)])
      end

      it "reads strings" do
        expect(env_config("POSTAL_WEB_HOSTNAME" => "mail.example.com").postal.web_hostname).to eq "mail.example.com"
      end

      it "reads integers" do
        expect(env_config("WEB_SERVER_DEFAULT_PORT" => "8080").web_server.default_port).to eq 8080
      end

      it "reads true and 1 as true" do
        expect(env_config("POSTAL_USE_IP_POOLS" => "true").postal.use_ip_pools?).to be true
        expect(env_config("POSTAL_USE_IP_POOLS" => "1").postal.use_ip_pools?).to be true
      end

      it "reads false, 0 and other strings as false" do
        expect(env_config("POSTAL_USE_IP_POOLS" => "false").postal.use_ip_pools?).to be false
        expect(env_config("POSTAL_USE_IP_POOLS" => "0").postal.use_ip_pools?).to be false
        expect(env_config("POSTAL_USE_IP_POOLS" => "yes").postal.use_ip_pools?).to be false
      end

      it "splits arrays on commas and strips whitespace" do
        expect(env_config("DNS_MX_RECORDS" => "mx1.example.com, mx2.example.com ,mx3.example.com").dns.mx_records).to eq ["mx1.example.com", "mx2.example.com", "mx3.example.com"]
      end

      it "reads a single value as a one element array" do
        expect(env_config("DNS_MX_RECORDS" => "mx1.example.com").dns.mx_records).to eq ["mx1.example.com"]
      end

      it "does not split arrays on spaces or newlines" do
        expect(env_config("DNS_MX_RECORDS" => "mx1.example.com mx2.example.com").dns.mx_records).to eq ["mx1.example.com mx2.example.com"]
        expect(env_config("DNS_MX_RECORDS" => "mx1.example.com\nmx2.example.com").dns.mx_records).to eq ["mx1.example.com\nmx2.example.com"]
      end

      it "transforms each array element" do
        relays = env_config("POSTAL_SMTP_RELAYS" => "smtp://a.example.com, smtp://b.example.com:587?ssl_mode=TLS").postal.smtp_relays.map(&:to_h)
        expect(relays).to eq [
          { "host" => "a.example.com", "port" => 25, "ssl_mode" => "Auto" },
          { "host" => "b.example.com", "port" => 587, "ssl_mode" => "TLS" },
        ]
        expect(env_config("POSTAL_TRUSTED_PROXIES" => "10.0.0.0/8,::1").postal.trusted_proxies).to eq [IPAddr.new("10.0.0.0/8"), IPAddr.new("::1")]
      end

      it "overrides array defaults" do
        expect(env_config("OIDC_SCOPES" => "openid,profile,email").oidc.scopes).to eq %w[openid profile email]
        expect(env_config({}).oidc.scopes).to eq %w[openid email]
      end

      it "substitutes the config file root" do
        expect(env_config("POSTAL_SIGNING_KEY_PATH" => "$CONFIG-FILE-ROOT/key.pem").postal.signing_key_path).to eq "#{File.dirname(Postal.config_file_path)}/key.pem"
      end
    end
  end

  RSpec.describe ".substitute_config_file_root" do
    let(:config_root) { File.dirname(Postal.config_file_path) }

    it "replaces the placeholder" do
      expect(Postal.substitute_config_file_root("$config-file-root/signing.key")).to eq "#{config_root}/signing.key"
    end

    it "replaces the placeholder case-insensitively" do
      expect(Postal.substitute_config_file_root("$CONFIG-FILE-ROOT/a")).to eq "#{config_root}/a"
      expect(Postal.substitute_config_file_root("$Config-File-Root/a")).to eq "#{config_root}/a"
    end

    it "replaces every occurrence" do
      expect(Postal.substitute_config_file_root("$config-file-root/a:$config-file-root/b")).to eq "#{config_root}/a:#{config_root}/b"
    end

    it "replaces the placeholder in the middle of a string" do
      expect(Postal.substitute_config_file_root("/srv/$config-file-root/a")).to eq "/srv/#{config_root}/a"
    end

    it "does not require a path separator after the placeholder" do
      expect(Postal.substitute_config_file_root("$config-file-rootx")).to eq "#{config_root}x"
    end

    it "leaves strings without the placeholder alone" do
      expect(Postal.substitute_config_file_root("/etc/postal/signing.key")).to eq "/etc/postal/signing.key"
      expect(Postal.substitute_config_file_root("")).to eq ""
    end

    it "does not replace similar placeholders" do
      expect(Postal.substitute_config_file_root("$config_file_root/a")).to eq "$config_file_root/a"
      expect(Postal.substitute_config_file_root("config-file-root/a")).to eq "config-file-root/a"
      expect(Postal.substitute_config_file_root("${config-file-root}/a")).to eq "${config-file-root}/a"
    end

    it "returns nil for nil" do
      expect(Postal.substitute_config_file_root(nil)).to be_nil
    end
  end

end
