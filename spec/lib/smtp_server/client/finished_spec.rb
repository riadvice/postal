# frozen_string_literal: true

require "rails_helper"

module SMTPServer

  describe Client do
    let(:ip_address) { "1.2.3.4" }
    let(:server) { create(:server) }
    subject(:client) { described_class.new(ip_address) }

    let(:credential) { create(:credential, server: server, type: "SMTP") }
    let(:auth_plain) { credential&.to_smtp_plain }
    let(:mail_from) { "test@example.com" }
    let(:rcpt_to) { "test@example.com" }

    before do
      client.handle("HELO test.example.com")
      client.handle("AUTH PLAIN #{auth_plain}") if auth_plain
      client.handle("MAIL FROM: #{mail_from}")
      client.handle("RCPT TO: #{rcpt_to}")
    end

    describe "when finished sending data" do
      context "when the . character does not end with a <CR>" do
        it "does nothing" do
          allow(Postal::Config.smtp_server).to receive(:max_message_size).and_return(1)
          client.handle("DATA")
          client.handle("Subject: Hello")
          client.handle("\r")
          expect(client.handle(".")).to be nil
        end
      end

      context "when the data before the . character does not end with a <CR>" do
        it "does nothing" do
          allow(Postal::Config.smtp_server).to receive(:max_message_size).and_return(1)
          client.handle("DATA")
          client.handle("Subject: Hello")
          expect(client.handle(".\r")).to be nil
        end
      end

      context "when the data is larger than the maximum message size" do
        it "returns an error and resets the state" do
          allow(Postal::Config.smtp_server).to receive(:max_message_size).and_return(1)
          client.handle("DATA")
          client.handle("a" * 1024 * 1024 * 10)
          client.handle("\r")
          expect(client.handle(".\r")).to eq "552 Message too large (maximum size 1MB)"
        end
      end

      context "when a loop is detected" do
        it "returns an error and resets the state" do
          client.handle("DATA")
          client.handle("Received: from example1.com by #{Postal::Config.postal.smtp_hostname}")
          client.handle("Received: from example2.com by #{Postal::Config.postal.smtp_hostname}")
          client.handle("Received: from example1.com by #{Postal::Config.postal.smtp_hostname}")
          client.handle("Received: from example2.com by #{Postal::Config.postal.smtp_hostname}")
          client.handle("Subject: Test")
          client.handle("From: #{mail_from}")
          client.handle("To: #{rcpt_to}")
          client.handle("")
          client.handle("This is a test message")
          client.handle("\r")
          expect(client.handle(".\r")).to eq "550 Loop detected"
        end
      end

      describe "loop detection" do
        let(:credential) { nil }
        let(:rcpt_to) { "#{server.token}@#{Postal::Config.dns.return_path_domain}" }
        let(:hostname) { Postal::Config.postal.smtp_hostname }

        def send_message(received_headers)
          client.handle("DATA")
          received_headers.each { |header| client.handle("Received: #{header}") }
          client.handle("Subject: Test")
          client.handle("")
          client.handle("This is a test message")
          client.handle("\r")
          client.handle(".\r")
        end

        it "accepts a message with three received headers from this host" do
          expect(send_message(["from a by #{hostname}"] * 3)).to eq "250 OK"
        end

        it "rejects a message with four received headers from this host" do
          expect(send_message(["from a by #{hostname}"] * 4)).to eq "550 Loop detected"
          expect(client.state).to eq :welcomed
          expect(client.recipients).to eq []
        end

        it "counts received headers with the host anywhere in the value" do
          expect(send_message(["from a by #{hostname} with SMTP; date", "by #{hostname}", "from b by #{hostname} (Postal)", "x by #{hostname}y"])).to eq "550 Loop detected"
        end

        it "counts received headers from a host that starts with this host" do
          expect(send_message(["from a by #{hostname}.evil.com"] * 4)).to eq "550 Loop detected"
        end

        it "does not count received headers from a host that ends with this host" do
          expect(send_message(["from a by mail.#{hostname}"] * 10)).to eq "250 OK"
        end

        it "counts received headers split over continuation lines" do
          client.handle("DATA")
          4.times do
            client.handle("Received: from a")
            client.handle(" by #{hostname}")
          end
          client.handle("")
          client.handle("\r")
          expect(client.handle(".\r")).to eq "550 Loop detected"
        end

        it "does not count received headers from other hosts" do
          expect(send_message(["from a by other.example.com"] * 10)).to eq "250 OK"
        end

        it "does not count received headers where the host is not preceded by by" do
          expect(send_message(["from #{hostname} by other.example.com"] * 10)).to eq "250 OK"
        end

        it "does not count received headers with more than one space before the host" do
          expect(send_message(["from a by  #{hostname}"] * 10)).to eq "250 OK"
        end

        it "does not count received headers with the host in a different case" do
          expect(send_message(["from a by #{hostname.upcase}"] * 10)).to eq "250 OK"
        end

        it "does not count other headers mentioning the host" do
          client.handle("DATA")
          10.times { client.handle("X-Received: from a by #{hostname}") }
          client.handle("")
          client.handle("\r")
          expect(client.handle(".\r")).to eq "250 OK"
        end

        it "does not count received headers where a dot in the hostname is another character" do
          expect(send_message(["from a by #{hostname.tr('.', '-')}"] * 10)).to eq "250 OK"
        end
      end

      context "when the email content is not suitable for the credential" do
        it "returns an error and resets the state" do
          client.handle("DATA")
          client.handle("Subject: Test")
          client.handle("From: invalid@krystal.uk")
          client.handle("To: #{rcpt_to}")
          client.handle("")
          client.handle("This is a test message")
          client.handle("\r")
          expect(client.handle(".\r")).to eq "530 From/Sender name is not valid"
        end
      end

      context "when sending an outgoing email" do
        let(:domain) { create(:domain, owner: server) }
        let(:mail_from) { "test@#{domain.name}" }
        let(:auth_plain) { credential.to_smtp_plain }

        it "stores the message and resets the state" do
          client.handle("DATA")
          client.handle("Subject: Test")
          client.handle("From: #{mail_from}")
          client.handle("To: #{rcpt_to}")
          client.handle("")
          client.handle("This is a test message")
          client.handle("\r")
          expect(client.handle(".\r")).to eq "250 OK"
          queued_message = QueuedMessage.first
          expect(queued_message).to have_attributes(
            domain: "example.com",
            server: server
          )

          expect(server.message(queued_message.message_id)).to have_attributes(
            mail_from: mail_from,
            rcpt_to: rcpt_to,
            subject: "Test",
            scope: "outgoing",
            route_id: nil,
            credential_id: credential.id,
            raw_headers: kind_of(String),
            raw_message: kind_of(String)
          )
        end
      end

      context "when sending a bounce message" do
        let(:credential) { nil }
        let(:rcpt_to) { "#{server.token}@#{Postal::Config.dns.return_path_domain}" }

        context "when there is a return path route" do
          let(:domain) { create(:domain, owner: server) }

          before do
            endpoint = create(:http_endpoint, server: server)
            create(:route, domain: domain, server: server, name: "__returnpath__", mode: "Endpoint", endpoint: endpoint)
          end

          it "stores the message for the return path route and resets the state" do
            client.handle("DATA")
            client.handle("Subject: Bounce: Test")
            client.handle("From: #{mail_from}")
            client.handle("To: #{rcpt_to}")
            client.handle("")
            client.handle("This is a test message")
            client.handle("\r")
            expect(client.handle(".\r")).to eq "250 OK"

            queued_message = QueuedMessage.first
            expect(queued_message).to have_attributes(
              domain: Postal::Config.dns.return_path_domain,
              server: server
            )

            expect(server.message(queued_message.message_id)).to have_attributes(
              mail_from: mail_from,
              rcpt_to: rcpt_to,
              subject: "Bounce: Test",
              scope: "incoming",
              route_id: server.routes.first.id,
              domain_id: domain.id,
              credential_id: nil,
              raw_headers: kind_of(String),
              raw_message: kind_of(String),
              bounce: true
            )
          end
        end

        context "when there is no return path route" do
          it "stores the message normally and resets the state" do
            client.handle("DATA")
            client.handle("Subject: Bounce: Test")
            client.handle("From: #{mail_from}")
            client.handle("To: #{rcpt_to}")
            client.handle("")
            client.handle("This is a test message")
            client.handle("\r")
            expect(client.handle(".\r")).to eq "250 OK"

            queued_message = QueuedMessage.first
            expect(queued_message).to have_attributes(
              domain: Postal::Config.dns.return_path_domain,
              server: server
            )

            expect(server.message(queued_message.message_id)).to have_attributes(
              mail_from: mail_from,
              rcpt_to: rcpt_to,
              subject: "Bounce: Test",
              scope: "incoming",
              route_id: nil,
              domain_id: nil,
              credential_id: nil,
              raw_headers: kind_of(String),
              raw_message: kind_of(String),
              bounce: true
            )
          end
        end
      end

      context "when receiving an incoming email" do
        let(:domain) { create(:domain, owner: server) }
        let(:route) { create(:route, server: server, domain: domain) }

        let(:credential) { nil }
        let(:rcpt_to) { "#{route.name}@#{domain.name}" }

        it "stores the message and resets the state" do
          client.handle("DATA")
          client.handle("Subject: Test")
          client.handle("From: #{mail_from}")
          client.handle("To: #{rcpt_to}")
          client.handle("")
          client.handle("This is a test message")
          client.handle("\r")
          expect(client.handle(".\r")).to eq "250 OK"

          queued_message = QueuedMessage.first
          expect(queued_message).to have_attributes(
            domain: domain.name,
            server: server
          )

          expect(server.message(queued_message.message_id)).to have_attributes(
            mail_from: mail_from,
            rcpt_to: rcpt_to,
            subject: "Test",
            scope: "incoming",
            route_id: route.id,
            domain_id: domain.id,
            credential_id: nil,
            raw_headers: kind_of(String),
            raw_message: kind_of(String)
          )
        end
      end
    end
  end

end
