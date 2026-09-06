# frozen_string_literal: true

require "rails_helper"

module SMTPServer

  describe Client do
    let(:ip_address) { "1.2.3.4" }
    subject(:client) { described_class.new(ip_address) }

    describe "log IP address exclusion" do
      let(:matcher) { nil }

      before do
        allow(Postal::Config.smtp_server).to receive(:log_ip_address_exclusion_matcher).and_return(matcher)
      end

      context "when no matcher is configured" do
        it "leaves logging enabled" do
          expect(client.logging_enabled).to be true
          expect(client.logger).not_to be_nil
        end
      end

      context "when the matcher is an empty string" do
        let(:matcher) { "" }

        it "disables logging for every address" do
          expect(client.logging_enabled).to be false
          expect(client.logger).to be_nil
        end
      end

      context "when the matcher is anchored" do
        let(:matcher) { "\\A10\\." }

        context "when the address matches" do
          let(:ip_address) { "10.0.0.1" }

          it "disables logging" do
            expect(client.logging_enabled).to be false
            expect(client.logger).to be_nil
          end
        end

        context "when the address does not match" do
          let(:ip_address) { "110.0.0.1" }

          it "leaves logging enabled" do
            expect(client.logging_enabled).to be true
          end
        end
      end

      context "when the matcher is not anchored" do
        let(:matcher) { "1.2.3" }

        context "when the address contains the match" do
          let(:ip_address) { "11.2.3.4" }

          it "disables logging" do
            expect(client.logging_enabled).to be false
          end
        end

        context "when a dot in the matcher is treated as a wildcard" do
          let(:ip_address) { "192.3.4.5" }

          it "disables logging" do
            expect(client.logging_enabled).to be false
          end
        end
      end

      context "when the matcher is a full alternation" do
        let(:matcher) { "\\A(127\\.0\\.0\\.1|::1)\\z" }

        it "matches the IPv4 loopback" do
          expect(described_class.new("127.0.0.1").logging_enabled).to be false
        end

        it "matches the IPv6 loopback" do
          expect(described_class.new("::1").logging_enabled).to be false
        end

        it "does not match an address with a suffix" do
          expect(described_class.new("127.0.0.10").logging_enabled).to be true
        end

        it "does not match an address with a prefix" do
          expect(described_class.new("::ffff:127.0.0.1").logging_enabled).to be true
        end
      end

      context "when the matcher is a character class" do
        let(:matcher) { "^10\\.[0-9]+\\.[0-9]+\\.[0-9]+$" }

        it "matches within the class" do
          expect(described_class.new("10.255.1.2").logging_enabled).to be false
        end

        it "does not match outside the class" do
          expect(described_class.new("10.a.1.2").logging_enabled).to be true
        end
      end

      context "when the client has no IP address yet" do
        let(:matcher) { ".*" }
        let(:ip_address) { nil }

        it "leaves logging enabled until PROXY identifies the client" do
          expect(client.logging_enabled).to be true
          client.handle("PROXY TCP4 1.1.1.1 2.2.2.2 1111 2222")
          expect(client.logging_enabled).to be false
        end
      end
    end

    describe "log sanitization" do
      def sanitize(data)
        client.send(:sanitize_input_for_log, data)
      end

      before do
        client.handle("HELO test.example.com")
      end

      context "when an AUTH command is sent on a single line" do
        it "redacts everything after the mechanism" do
          expect(sanitize("AUTH PLAIN AHVzZXIAcGFzcw==")).to eq "AUTH PLAIN [redacted]"
          expect(sanitize("AUTH LOGIN dXNlcg==")).to eq "AUTH LOGIN [redacted]"
        end

        it "redacts case-insensitively" do
          expect(sanitize("auth plain AHVzZXIAcGFzcw==")).to eq "auth plain [redacted]"
          expect(sanitize("Auth Login dXNlcg==")).to eq "Auth Login [redacted]"
        end

        it "redacts multiple space separated values" do
          expect(sanitize("AUTH PLAIN one two three")).to eq "AUTH PLAIN [redacted]"
        end

        it "redacts values that are not base64" do
          expect(sanitize("AUTH PLAIN !!! not base64")).to eq "AUTH PLAIN [redacted]"
        end

        it "redacts when the command is preceded by other text" do
          expect(sanitize("xx AUTH PLAIN secret")).to eq "xx AUTH PLAIN [redacted]"
        end

        it "leaves a bare AUTH command alone" do
          expect(sanitize("AUTH PLAIN")).to eq "AUTH PLAIN"
          expect(sanitize("AUTH LOGIN")).to eq "AUTH LOGIN"
          expect(sanitize("AUTH CRAM-MD5")).to eq "AUTH CRAM-MD5"
        end

        it "leaves a MAIL FROM with an AUTH parameter alone" do
          expect(sanitize("MAIL FROM:<test@example.com> AUTH=<>")).to eq "MAIL FROM:<test@example.com> AUTH=<>"
        end

        it "leaves other commands alone" do
          expect(sanitize("HELO test.example.com")).to eq "HELO test.example.com"
          expect(sanitize("RCPT TO:<auth@example.com>")).to eq "RCPT TO:<auth@example.com>"
          expect(sanitize("Subject: AUTHOR list")).to eq "Subject: AUTHOR list"
        end

        it "does not modify the original string" do
          data = "AUTH PLAIN secret"
          sanitize(data)
          expect(data).to eq "AUTH PLAIN secret"
        end
      end

      context "when a password is expected on the next line" do
        before do
          client.handle("AUTH LOGIN")
          client.handle("dXNlcg==")
        end

        it "redacts a base64 value" do
          expect(sanitize("cGFzc3dvcmQ=")).to eq "[redacted]"
        end

        it "redacts a base64 value without padding" do
          expect(sanitize("cGFzc3dvcmQ")).to eq "[redacted]"
        end

        it "redacts a base64 value with double padding" do
          expect(sanitize("cGFzcw==")).to eq "[redacted]"
        end

        it "redacts an uppercase and numeric value" do
          expect(sanitize("ABC123")).to eq "[redacted]"
        end

        it "only redacts once" do
          expect(sanitize("cGFzc3dvcmQ=")).to eq "[redacted]"
          expect(sanitize("cGFzc3dvcmQ=")).to eq "cGFzc3dvcmQ="
        end

        it "does not redact a value shorter than three characters" do
          expect(sanitize("ab")).to eq "ab"
        end

        it "does not redact a value with padding in the middle" do
          expect(sanitize("abc=def")).to eq "abc=def"
        end

        it "does not redact a value containing spaces" do
          expect(sanitize("abc def")).to eq "abc def"
        end

        it "does not redact a value containing a line feed" do
          expect(sanitize("abc\ndef")).to eq "abc\ndef"
        end

        it "redacts a base64 value containing plus or slash" do
          expect(sanitize("+/8=")).to eq "[redacted]"
        end
      end

      context "when a password is expected after AUTH PLAIN" do
        before do
          client.handle("AUTH PLAIN")
        end

        it "redacts the next line" do
          expect(sanitize("AHVzZXIAcGFzcw==")).to eq "[redacted]"
        end
      end

      context "when a password is not expected" do
        it "does not redact a base64 looking value" do
          expect(sanitize("cGFzc3dvcmQ=")).to eq "cGFzc3dvcmQ="
        end

        it "does not redact after a username was expected" do
          client.handle("AUTH LOGIN")
          expect(sanitize("dXNlcg==")).to eq "dXNlcg=="
        end
      end
    end
  end

end
