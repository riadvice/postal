# frozen_string_literal: true

require "rails_helper"

module SMTPServer

  describe Client do
    let(:ip_address) { "1.2.3.4" }
    subject(:client) { described_class.new(ip_address) }

    describe "command dispatch" do
      it "returns an error for an unknown command" do
        expect(client.handle("HELP")).to eq "502 Invalid/unsupported command"
      end

      it "returns an error for an empty line" do
        expect(client.handle("")).to eq "502 Invalid/unsupported command"
      end

      it "returns an error for a line containing only whitespace" do
        expect(client.handle("   ")).to eq "502 Invalid/unsupported command"
      end

      it "returns an error when a command is preceded by whitespace" do
        expect(client.handle(" QUIT")).to eq "502 Invalid/unsupported command"
        expect(client.handle("\tNOOP")).to eq "502 Invalid/unsupported command"
        expect(client.finished?).to be false
      end

      it "returns an error when a command is preceded by other text" do
        expect(client.handle("XQUIT")).to eq "502 Invalid/unsupported command"
        expect(client.handle("something QUIT")).to eq "502 Invalid/unsupported command"
      end

      it "returns an error when the two word commands are joined" do
        expect(client.handle("MAILFROM: test@example.com")).to eq "502 Invalid/unsupported command"
        expect(client.handle("RCPTTO: test@example.com")).to eq "502 Invalid/unsupported command"
        expect(client.handle("AUTHPLAIN")).to eq "502 Invalid/unsupported command"
      end

      it "returns an error when the two word commands are separated by more than one space" do
        expect(client.handle("MAIL  FROM: test@example.com")).to eq "502 Invalid/unsupported command"
        expect(client.handle("RCPT  TO: test@example.com")).to eq "502 Invalid/unsupported command"
        expect(client.handle("AUTH  PLAIN")).to eq "502 Invalid/unsupported command"
        expect(client.handle("AUTH\tLOGIN")).to eq "502 Invalid/unsupported command"
      end

      it "returns an error for an unsupported AUTH mechanism" do
        expect(client.handle("AUTH DIGEST-MD5")).to eq "502 Invalid/unsupported command"
        expect(client.handle("AUTH")).to eq "502 Invalid/unsupported command"
      end

      it "returns an error for PROXY once the client has been welcomed" do
        expect(client.handle("PROXY TCP4 1.1.1.1 2.2.2.2 1111 2222")).to eq "502 Invalid/unsupported command"
        expect(client.ip_address).to eq "1.2.3.4"
      end

      it "handles a very long unknown command" do
        expect(client.handle("X" * 100_000)).to eq "502 Invalid/unsupported command"
      end

      it "handles a line with a trailing <CR>" do
        expect(client.handle("NOOP\r")).to eq "250 OK"
      end

      it "matches commands case-insensitively" do
        expect(client.handle("noop")).to eq "250 OK"
        expect(client.handle("NoOp")).to eq "250 OK"
        expect(client.handle("helo test.example.com")).to eq "250 #{Postal::Config.postal.smtp_hostname}"
        expect(client.handle("ehlo test.example.com")).to include "250-My capabilities are"
        expect(client.handle("rset")).to eq "250 OK"
        expect(client.handle("mail from:<test@example.com>")).to eq "250 OK"
        expect(client.handle("rcpt to:<>")).to eq "501 RCPT TO should not be empty"
        expect(client.handle("Mail From:<test@example.com>")).to eq "250 OK"
        expect(client.handle("auth plain")).to eq "334"
        client.handle("")
        expect(client.handle("auth login")).to eq "334 VXNlcm5hbWU6"
        client.handle("")
        client.handle("")
        expect(client.handle("auth cram-md5")).to match(/\A334 /)
      end

      it "matches DATA case-insensitively" do
        expect(client.handle("data")).to eq "503 HELO/EHLO, MAIL FROM and RCPT TO before sending data"
      end

      it "matches QUIT case-insensitively" do
        expect(client.handle("quit")).to eq "221 Closing Connection"
        expect(client.finished?).to be true
      end

      it "matches STARTTLS case-insensitively" do
        allow(Postal::Config.smtp_server).to receive(:tls_enabled?).and_return(true)
        expect(client.handle("starttls")).to eq "220 Ready to start TLS"
      end

      it "only requires the command to appear at the start of the line" do
        expect(client.handle("NOOPS")).to eq "250 OK"
        expect(client.handle("NOOP anything else")).to eq "250 OK"
        expect(client.handle("RSET now")).to eq "250 OK"
        expect(client.handle("HELOWORLD")).to eq "250 #{Postal::Config.postal.smtp_hostname}"
        expect(client.helo_name).to be_nil
        expect(client.handle("DATABASE")).to eq "503 HELO/EHLO, MAIL FROM and RCPT TO before sending data"
        expect(client.handle("QUITTING")).to eq "221 Closing Connection"
      end

      it "does not match a command that appears after a line feed" do
        expect(client.handle("garbage\nQUIT")).to eq "502 Invalid/unsupported command"
        expect(client.finished?).to be false
      end
    end

    describe "QUIT" do
      it "closes the connection" do
        expect(client.handle("QUIT")).to eq "221 Closing Connection"
        expect(client.finished?).to be true
      end

      it "closes the connection with a trailing <CR>" do
        expect(client.handle("QUIT\r")).to eq "221 Closing Connection"
        expect(client.finished?).to be true
      end
    end

    describe "NOOP" do
      it "returns OK without changing state" do
        expect(client.handle("NOOP")).to eq "250 OK"
        expect(client.state).to eq :welcome
      end

      it "does not reset the transaction" do
        client.handle("HELO test.example.com")
        client.handle("MAIL FROM:<test@example.com>")
        expect(client.handle("NOOP")).to eq "250 OK"
        expect(client.state).to eq :mail_from_received
        expect(client.instance_variable_get("@mail_from")).to eq "test@example.com"
      end
    end

    describe "RSET" do
      it "returns OK and resets the transaction" do
        client.handle("HELO test.example.com")
        client.handle("MAIL FROM:<test@example.com>")
        expect(client.handle("RSET")).to eq "250 OK"
        expect(client.state).to eq :welcomed
        expect(client.instance_variable_get("@mail_from")).to be_nil
        expect(client.recipients).to eq []
      end

      it "moves the client to the welcomed state even before HELO" do
        expect(client.handle("RSET")).to eq "250 OK"
        expect(client.state).to eq :welcomed
      end
    end

    describe "STARTTLS" do
      context "when TLS is enabled" do
        before do
          allow(Postal::Config.smtp_server).to receive(:tls_enabled?).and_return(true)
        end

        it "returns ready and flags the client to start TLS" do
          expect(client.handle("STARTTLS")).to eq "220 Ready to start TLS"
          expect(client.start_tls?).to be true
        end

        it "no longer advertises STARTTLS on the next EHLO" do
          client.handle("STARTTLS")
          expect(client.handle("EHLO test.example.com")).to eq ["250-My capabilities are",
                                                                "250 AUTH CRAM-MD5 PLAIN LOGIN",]
        end
      end

      context "when TLS is not enabled" do
        it "returns an error" do
          expect(client.handle("STARTTLS")).to eq "502 TLS not available"
          expect(client.start_tls?).to be false
        end
      end
    end
  end

end
