# frozen_string_literal: true

require "rails_helper"

module SMTPServer

  describe Client do
    let(:ip_address) { nil }
    subject(:client) { described_class.new(ip_address) }

    describe "PROXY" do
      let(:welcome) { "220 #{Postal::Config.postal.smtp_hostname} ESMTP Postal/#{client.trace_id}" }

      it "starts in the preauth state" do
        expect(client.state).to eq :preauth
        expect(client.ip_address).to be_nil
      end

      context "when the proxy header is sent correctly" do
        it "sets the IP address" do
          expect(client.handle("PROXY TCP4 1.1.1.1 2.2.2.2 1111 2222")).to eq "220 #{Postal::Config.postal.smtp_hostname} ESMTP Postal/#{client.trace_id}"
          expect(client.ip_address).to eq "1.1.1.1"
        end

        it "moves the client to the welcome state" do
          client.handle("PROXY TCP4 1.1.1.1 2.2.2.2 1111 2222")
          expect(client.state).to eq :welcome
          expect(client.finished?).to be false
        end

        it "accepts IPv6 addresses" do
          expect(client.handle("PROXY TCP6 2001:db8::1 2001:db8::2 1111 2222")).to eq welcome
          expect(client.ip_address).to eq "2001:db8::1"
        end

        it "accepts an IPv4-mapped IPv6 address without altering it" do
          expect(client.handle("PROXY TCP6 ::ffff:1.1.1.1 ::ffff:2.2.2.2 1111 2222")).to eq welcome
          expect(client.ip_address).to eq "::ffff:1.1.1.1"
        end

        it "accepts a line with a trailing <CR>" do
          expect(client.handle("PROXY TCP4 1.1.1.1 2.2.2.2 1111 2222\r")).to eq welcome
          expect(client.ip_address).to eq "1.1.1.1"
        end

        it "does not validate the contents of the fields" do
          expect(client.handle("PROXY foo bar baz qux quux")).to eq welcome
          expect(client.ip_address).to eq "bar"
        end

        it "allows normal commands afterwards" do
          client.handle("PROXY TCP4 1.1.1.1 2.2.2.2 1111 2222")
          expect(client.handle("HELO test.example.com")).to eq "250 #{Postal::Config.postal.smtp_hostname}"
          expect(client.state).to eq :welcomed
        end

        it "treats a second PROXY line as an invalid command" do
          client.handle("PROXY TCP4 1.1.1.1 2.2.2.2 1111 2222")
          expect(client.handle("PROXY TCP4 3.3.3.3 4.4.4.4 1111 2222")).to eq "502 Invalid/unsupported command"
          expect(client.ip_address).to eq "1.1.1.1"
        end

        it "uses the proxied IP for the log exclusion matcher" do
          allow(Postal::Config.smtp_server).to receive(:log_ip_address_exclusion_matcher).and_return("\\A10\\.")
          expect(client.logging_enabled).to be true
          client.handle("PROXY TCP4 10.0.0.1 2.2.2.2 1111 2222")
          expect(client.logging_enabled).to be false
        end

        it "keeps logging enabled when the proxied IP does not match the exclusion matcher" do
          allow(Postal::Config.smtp_server).to receive(:log_ip_address_exclusion_matcher).and_return("\\A10\\.")
          client.handle("PROXY TCP4 11.0.0.1 2.2.2.2 1111 2222")
          expect(client.logging_enabled).to be true
        end
      end

      context "when the proxy header is not valid" do
        it "returns an error" do
          expect(client.handle("PROXY TCP4")).to eq "502 Proxy Error"
          expect(client.finished?).to be true
        end

        it "returns an error when a field is missing" do
          expect(client.handle("PROXY TCP4 1.1.1.1 2.2.2.2 1111")).to eq "502 Proxy Error"
          expect(client.finished?).to be true
          expect(client.state).to eq :preauth
          expect(client.ip_address).to be_nil
        end

        it "returns an error for the UNKNOWN protocol form" do
          expect(client.handle("PROXY UNKNOWN")).to eq "502 Proxy Error"
          expect(client.finished?).to be true
        end

        it "returns an error when a field is empty" do
          expect(client.handle("PROXY TCP4  2.2.2.2 1111 2222")).to eq "502 Proxy Error"
          expect(client.handle("PROXY TCP4 1.1.1.1 2.2.2.2 1111 ")).to eq "502 Proxy Error"
        end

        it "is case-sensitive" do
          expect(client.handle("proxy TCP4 1.1.1.1 2.2.2.2 1111 2222")).to eq "502 Proxy Error"
          expect(client.finished?).to be true
        end

        it "returns an error when PROXY is not at the start of the line" do
          expect(client.handle(" PROXY TCP4 1.1.1.1 2.2.2.2 1111 2222")).to eq "502 Proxy Error"
          expect(client.handle("xPROXY TCP4 1.1.1.1 2.2.2.2 1111 2222")).to eq "502 Proxy Error"
        end

        it "returns an error when fields are separated by tabs" do
          expect(client.handle("PROXY\tTCP4\t1.1.1.1\t2.2.2.2\t1111\t2222")).to eq "502 Proxy Error"
        end

        it "returns an error when the line contains a line feed" do
          expect(client.handle("PROXY TCP4 1.1.1.1 2.2.2.2 1111 2222\nQUIT")).to eq "502 Proxy Error"
          expect(client.handle("PROXY TCP4 1.1.1.1\n2.2.2.2 1111 2222")).to eq "502 Proxy Error"
        end

        it "returns an error for any other command before PROXY" do
          expect(client.handle("HELO test.example.com")).to eq "502 Proxy Error"
          expect(client.finished?).to be true
          expect(client.state).to eq :preauth
        end

        it "returns an error for an empty line" do
          expect(client.handle("")).to eq "502 Proxy Error"
          expect(client.finished?).to be true
        end

        it "returns an error for a very long line" do
          expect(client.handle("PROXY " + ("A" * 100_000))).to eq "502 Proxy Error"
        end
      end

      context "when the proxy header has too many fields" do
        it "rejects the line" do
          expect(client.handle("PROXY TCP4 1.1.1.1 2.2.2.2 1111 2222 3333")).to eq "502 Proxy Error"
        end

        it "does not use the wrong field as the client IP" do
          client.handle("PROXY TCP4 1.1.1.1 2.2.2.2 1111 2222 3333")
          expect(client.ip_address).not_to eq "2.2.2.2"
        end
      end
    end
  end

end
