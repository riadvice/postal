# frozen_string_literal: true

require "rails_helper"

module SMTPServer

  describe Client do
    let(:ip_address) { "1.2.3.4" }
    subject(:client) { described_class.new(ip_address) }

    describe "HELO" do
      it "returns the hostname" do
        expect(client.state).to eq :welcome
        expect(client.handle("HELO: test.example.com")).to eq "250 #{Postal::Config.postal.smtp_hostname}"
        expect(client.state).to eq :welcomed
      end

      it "sets the helo name" do
        client.handle("HELO test.example.com")
        expect(client.helo_name).to eq "test.example.com"
      end

      it "sets the helo name when a colon follows the command" do
        client.handle("HELO: test.example.com")
        expect(client.helo_name).to eq "test.example.com"
      end

      it "sets the helo name when the command is lowercase" do
        client.handle("helo test.example.com")
        expect(client.helo_name).to eq "test.example.com"
      end

      it "ignores extra whitespace between the command and the name" do
        client.handle("HELO    test.example.com")
        expect(client.helo_name).to eq "test.example.com"
      end

      it "ignores whitespace around the line" do
        client.handle("HELO test.example.com   \r")
        expect(client.helo_name).to eq "test.example.com"
      end

      it "keeps everything after the first space as the name" do
        client.handle("HELO test.example.com something else")
        expect(client.helo_name).to eq "test.example.com something else"
      end

      it "sets no helo name when none is provided" do
        expect(client.handle("HELO")).to eq "250 #{Postal::Config.postal.smtp_hostname}"
        expect(client.helo_name).to be_nil
      end

      it "sets no helo name when only whitespace follows" do
        expect(client.handle("HELO   ")).to eq "250 #{Postal::Config.postal.smtp_hostname}"
        expect(client.helo_name).to be_nil
      end

      it "accepts an address literal" do
        client.handle("HELO [1.2.3.4]")
        expect(client.helo_name).to eq "[1.2.3.4]"
      end

      it "accepts a unicode name" do
        client.handle("HELO exämple.com")
        expect(client.helo_name).to eq "exämple.com"
      end

      it "accepts a very long name" do
        name = "a" * 10_000
        client.handle("HELO #{name}")
        expect(client.helo_name).to eq name
      end

      it "resets the transaction" do
        client.handle("HELO test.example.com")
        client.handle("MAIL FROM:<test@example.com>")
        expect(client.handle("HELO test2.example.com")).to eq "250 #{Postal::Config.postal.smtp_hostname}"
        expect(client.state).to eq :welcomed
        expect(client.instance_variable_get("@mail_from")).to be_nil
        expect(client.helo_name).to eq "test2.example.com"
      end
    end

    describe "EHLO" do
      it "returns the capabilities" do
        expect(client.handle("EHLO test.example.com")).to eq ["250-My capabilities are",
                                                              "250 AUTH CRAM-MD5 PLAIN LOGIN",]
      end

      it "sets the helo name" do
        client.handle("EHLO test.example.com")
        expect(client.helo_name).to eq "test.example.com"
        expect(client.state).to eq :welcomed
      end

      it "sets the helo name when the command is lowercase" do
        client.handle("ehlo test.example.com")
        expect(client.helo_name).to eq "test.example.com"
      end

      it "sets no helo name when none is provided" do
        expect(client.handle("EHLO")).to include "250-My capabilities are"
        expect(client.helo_name).to be_nil
      end

      it "ignores extra whitespace between the command and the name" do
        client.handle("EHLO \t test.example.com")
        expect(client.helo_name).to eq "test.example.com"
      end

      context "when TLS is enabled" do
        it "returns capabilities include starttls" do
          allow(Postal::Config.smtp_server).to receive(:tls_enabled?).and_return(true)
          expect(client.handle("EHLO test.example.com")).to eq ["250-My capabilities are",
                                                                "250-STARTTLS",
                                                                "250 AUTH CRAM-MD5 PLAIN LOGIN",]
        end
      end
    end
  end

end
