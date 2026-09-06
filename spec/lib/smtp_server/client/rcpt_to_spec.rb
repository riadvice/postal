# frozen_string_literal: true

require "rails_helper"

module SMTPServer

  describe Client do
    let(:ip_address) { "1.2.3.4" }
    subject(:client) { described_class.new(ip_address) }

    describe "RCPT TO" do
      let(:helo) { "test.example.com" }
      let(:mail_from) { "test@example.com" }

      before do
        client.handle("HELO #{helo}")
        client.handle("MAIL FROM: #{mail_from}") if mail_from
      end

      context "when MAIL FROM has not been sent" do
        let(:mail_from) { nil }

        it "returns an error if RCPT TO is sent before MAIL FROM" do
          expect(client.handle("RCPT TO: no-route-here@internal.com")).to eq "503 EHLO/HELO and MAIL FROM first please"
          expect(client.state).to eq :welcomed
        end
      end

      it "returns an error if RCPT TO is not valid" do
        expect(client.handle("RCPT TO: blah")).to eq "501 Invalid RCPT TO"
      end

      it "returns an error if RCPT TO is empty" do
        expect(client.handle("RCPT TO: ")).to eq "501 RCPT TO should not be empty"
      end

      describe "address extraction" do
        let(:server) { create(:server) }
        let(:credential) { create(:credential, server: server, type: "SMTP") }

        before do
          client.handle("AUTH PLAIN #{credential.to_smtp_plain}")
        end

        def rcpt_to(line)
          expect(client.handle(line)).to eq "250 OK"
          client.recipients.last[1]
        end

        it "extracts an address in angle brackets" do
          expect(rcpt_to("RCPT TO:<test@example.com>")).to eq "test@example.com"
        end

        it "extracts an address in angle brackets after a space" do
          expect(rcpt_to("RCPT TO: <test@example.com>")).to eq "test@example.com"
        end

        it "extracts an address with spaces around the colon" do
          expect(rcpt_to("RCPT TO : <test@example.com>")).to eq "test@example.com"
          expect(rcpt_to("RCPT TO\t:\t<test@example.com>")).to eq "test@example.com"
        end

        it "extracts an address without angle brackets" do
          expect(rcpt_to("RCPT TO: test@example.com")).to eq "test@example.com"
          expect(rcpt_to("RCPT TO:test@example.com")).to eq "test@example.com"
        end

        it "extracts an address without a colon" do
          expect(rcpt_to("RCPT TO <test@example.com>")).to eq "test@example.com"
        end

        it "extracts an address when the command is lowercase" do
          expect(rcpt_to("rcpt to:<test@example.com>")).to eq "test@example.com"
          expect(rcpt_to("Rcpt To: <test@example.com>")).to eq "test@example.com"
        end

        it "strips whitespace around the address" do
          expect(rcpt_to("RCPT TO:< test@example.com >")).to eq "test@example.com"
          expect(rcpt_to("RCPT TO: test@example.com   ")).to eq "test@example.com"
          expect(rcpt_to("RCPT TO:<test@example.com>\r")).to eq "test@example.com"
        end

        it "extracts an address with a plus tag" do
          expect(rcpt_to("RCPT TO:<test+tag@example.com>")).to eq "test+tag@example.com"
        end

        it "extracts an address with a quoted local part" do
          expect(rcpt_to("RCPT TO:<\"john doe\"@example.com>")).to eq "\"john doe\"@example.com"
        end

        it "extracts a unicode address" do
          expect(rcpt_to("RCPT TO:<jöhn@exämple.com>")).to eq "jöhn@exämple.com"
        end

        it "extracts a very long address" do
          address = "#{'a' * 5000}@#{'b' * 5000}.com"
          expect(rcpt_to("RCPT TO:<#{address}>")).to eq address
        end

        it "preserves the case of the address" do
          expect(rcpt_to("RCPT TO:<Test@Example.COM>")).to eq "Test@Example.COM"
        end

        it "extracts an address containing multiple @ signs" do
          expect(rcpt_to("RCPT TO:<\"a@b\"@example.com>")).to eq "\"a@b\"@example.com"
        end

        it "discards parameters" do
          expect(rcpt_to("RCPT TO:<test@example.com> NOTIFY=SUCCESS,FAILURE")).to eq "test@example.com"
          expect(rcpt_to("RCPT TO:<test@example.com> NOTIFY=NEVER ORCPT=rfc822;test@example.com")).to eq "test@example.com"
          expect(rcpt_to("RCPT TO:<test@example.com>NOTIFY=NEVER")).to eq "test@example.com"
        end

        it "discards parameters when the address has no angle brackets" do
          expect(rcpt_to("RCPT TO: test@example.com NOTIFY=NEVER")).to eq "test@example.com"
        end

        it "handles malformed brackets" do
          expect(rcpt_to("RCPT TO:<test@example.com")).to eq "test@example.com"
          expect(rcpt_to("RCPT TO: test@example.com>")).to eq "test@example.com"
          expect(rcpt_to("RCPT TO:<<test@example.com>>")).to eq "test@example.com"
          expect(rcpt_to("RCPT TO:<a@b.com> <test@example.com>")).to eq "a@b.com"
        end

        it "strips a carriage return in the middle of the line" do
          expect(rcpt_to("RCPT TO:<test@example.com>\rQUIT")).to eq "test@example.com"
        end

        it "returns an error for a null sender" do
          expect(client.handle("RCPT TO:<>")).to eq "501 RCPT TO should not be empty"
          expect(client.recipients).to eq []
        end

        it "returns an error for a missing address" do
          expect(client.handle("RCPT TO:")).to eq "501 RCPT TO should not be empty"
          expect(client.handle("RCPT TO: ")).to eq "501 RCPT TO should not be empty"
          expect(client.handle("RCPT TO:<><>")).to eq "501 RCPT TO should not be empty"
        end

        it "returns an error when the colon is missing" do
          expect(client.handle("RCPT TO")).to eq "501 RCPT TO should not be empty"
        end

        it "returns an error for an address with no domain" do
          expect(client.handle("RCPT TO:<test>")).to eq "501 Invalid RCPT TO"
          expect(client.handle("RCPT TO:<test@>")).to eq "501 Invalid RCPT TO"
        end

        it "accepts an address with no local part" do
          expect(rcpt_to("RCPT TO:<@example.com>")).to eq "@example.com"
        end

        it "returns an error when the state has not been reached" do
          expect(client.handle("RCPT TO:<test@example.com>")).to eq "250 OK"
          client.handle("RSET")
          expect(client.handle("RCPT TO:<test@example.com>")).to eq "503 EHLO/HELO and MAIL FROM first please"
        end
      end

      describe "return path detection" do
        let(:server) { create(:server) }
        let(:return_path_domain) { Postal::Config.dns.return_path_domain }
        let(:prefix) { Postal::Config.dns.custom_return_path_prefix }

        it "detects the return path domain" do
          expect(client.handle("RCPT TO:<#{server.token}@#{return_path_domain}>")).to eq "250 OK"
          expect(client.recipients).to eq [[:bounce, "#{server.token}@#{return_path_domain}", server]]
        end

        it "does not detect a subdomain of the return path domain" do
          expect(client.handle("RCPT TO:<#{server.token}@sub.#{return_path_domain}>")).to eq "530 Authentication required"
        end

        it "does not detect a superdomain of the return path domain" do
          expect(client.handle("RCPT TO:<#{server.token}@#{return_path_domain}.evil.com>")).to eq "530 Authentication required"
        end

        it "detects the custom return path prefix on any domain" do
          expect(client.handle("RCPT TO:<#{server.token}@#{prefix}.example.com>")).to eq "250 OK"
          expect(client.handle("RCPT TO:<#{server.token}@#{prefix}.another.example.org>")).to eq "250 OK"
          expect(client.handle("RCPT TO:<#{server.token}@#{prefix}.x>")).to eq "250 OK"
        end

        it "detects the custom return path prefix on the return path domain" do
          expect(client.handle("RCPT TO:<#{server.token}@#{prefix}.#{return_path_domain}>")).to eq "250 OK"
        end

        it "does not detect the prefix without a following dot" do
          expect(client.handle("RCPT TO:<#{server.token}@#{prefix}>")).to eq "530 Authentication required"
          expect(client.handle("RCPT TO:<#{server.token}@#{prefix}example.com>")).to eq "530 Authentication required"
          expect(client.handle("RCPT TO:<#{server.token}@#{prefix}-x.example.com>")).to eq "530 Authentication required"
        end

        it "does not detect the prefix when it is not the first label" do
          expect(client.handle("RCPT TO:<#{server.token}@x#{prefix}.example.com>")).to eq "530 Authentication required"
          expect(client.handle("RCPT TO:<#{server.token}@mail.#{prefix}.example.com>")).to eq "530 Authentication required"
        end

        it "detects the prefix case-insensitively" do
          expect(client.handle("RCPT TO:<#{server.token}@#{prefix.upcase}.example.com>")).to eq "250 OK"
          expect(client.handle("RCPT TO:<#{server.token}@#{return_path_domain.upcase}>")).to eq "250 OK"
        end

        it "uses the local part before the tag as the server token" do
          expect(client.handle("RCPT TO:<#{server.token}+tag@#{return_path_domain}>")).to eq "250 OK"
          expect(client.recipients).to eq [[:bounce, "#{server.token}+tag@#{return_path_domain}", server]]
        end

        it "uses the local part before the first plus as the server token" do
          expect(client.handle("RCPT TO:<#{server.token}+a+b@#{return_path_domain}>")).to eq "250 OK"
          expect(client.handle("RCPT TO:<x+#{server.token}@#{return_path_domain}>")).to eq "550 Invalid server token"
        end

        it "returns an error for an empty server token" do
          expect(client.handle("RCPT TO:<@#{return_path_domain}>")).to eq "550 Invalid server token"
          expect(client.handle("RCPT TO:<+tag@#{return_path_domain}>")).to eq "550 Invalid server token"
        end

        context "when the prefix contains regular expression characters" do
          before do
            allow(Postal::Config.dns).to receive(:custom_return_path_prefix).and_return("ps.rp")
          end

          it "matches the prefix literally" do
            expect(client.handle("RCPT TO:<#{server.token}@ps.rp.example.com>")).to eq "250 OK"
          end

          it "does not treat the dot as a wildcard" do
            expect(client.handle("RCPT TO:<#{server.token}@psxrp.example.com>")).to eq "530 Authentication required"
          end
        end
      end

      describe "route domain detection" do
        let(:route_domain) { Postal::Config.dns.route_domain }
        let(:server) { create(:server) }
        let(:route) { create(:route, server: server) }

        it "does not detect a subdomain of the route domain" do
          expect(client.handle("RCPT TO:<#{route.token}@sub.#{route_domain}>")).to eq "530 Authentication required"
        end

        it "adds the tag with multiple plus signs" do
          expect(client.handle("RCPT TO:<#{route.token}+a+b@#{route_domain}>")).to eq "250 OK"
          expect(client.recipients).to eq [[:route, "#{route.name}+a+b@#{route.domain.name}", server, { route: route }]]
        end

        it "adds no tag when there is no plus" do
          expect(client.handle("RCPT TO:<#{route.token}@#{route_domain}>")).to eq "250 OK"
          expect(client.recipients).to eq [[:route, "#{route.name}@#{route.domain.name}", server, { route: route }]]
        end

        it "adds an empty tag when the plus is trailing" do
          expect(client.handle("RCPT TO:<#{route.token}+@#{route_domain}>")).to eq "250 OK"
          expect(client.recipients).to eq [[:route, "#{route.name}+@#{route.domain.name}", server, { route: route }]]
        end
      end

      describe "incoming route lookup" do
        let(:server) { create(:server) }
        let(:route) { create(:route, server: server) }

        it "keeps the tag in the recipient" do
          expect(client.handle("RCPT TO:<#{route.name}+tag@#{route.domain.name}>")).to eq "250 OK"
          expect(client.recipients).to eq [[:route, "#{route.name}+tag@#{route.domain.name}", server, { route: route }]]
        end

        it "looks up the route by the local part before the tag" do
          expect(client.handle("RCPT TO:<#{route.name}+a+b@#{route.domain.name}>")).to eq "250 OK"
          expect(client.handle("RCPT TO:<tag+#{route.name}@#{route.domain.name}>")).to eq "530 Authentication required"
        end

        it "does not match a subdomain of the route domain" do
          expect(client.handle("RCPT TO:<#{route.name}@sub.#{route.domain.name}>")).to eq "530 Authentication required"
        end

        it "does not match a domain with a suffix" do
          expect(client.handle("RCPT TO:<#{route.name}@#{route.domain.name}.evil.com>")).to eq "530 Authentication required"
        end
      end

      context "when the RCPT TO address is the system return path host" do
        it "returns an error if the server does not exist" do
          expect(client.handle("RCPT TO: nothing@#{Postal::Config.dns.return_path_domain}")).to eq "550 Invalid server token"
        end

        it "returns an error if the server is suspended" do
          server = create(:server, :suspended)
          expect(client.handle("RCPT TO: #{server.token}@#{Postal::Config.dns.return_path_domain}"))
            .to eq "535 Mail server has been suspended"
        end

        it "adds a recipient if all OK" do
          server = create(:server)
          address = "#{server.token}@#{Postal::Config.dns.return_path_domain}"
          expect(client.handle("RCPT TO: #{address}")).to eq "250 OK"
          expect(client.recipients).to eq [[:bounce, address, server]]
          expect(client.state).to eq :rcpt_to_received
        end
      end

      context "when the RCPT TO address is on a host using the return path prefix" do
        it "returns an error if the server does not exist" do
          address = "nothing@#{Postal::Config.dns.custom_return_path_prefix}.example.com"
          expect(client.handle("RCPT TO: #{address}")).to eq "550 Invalid server token"
        end

        it "returns an error if the server is suspended" do
          server = create(:server, :suspended)
          address = "#{server.token}@#{Postal::Config.dns.custom_return_path_prefix}.example.com"
          expect(client.handle("RCPT TO: #{address}")).to eq "535 Mail server has been suspended"
        end

        it "adds a recipient if all OK" do
          server = create(:server)
          address = "#{server.token}@#{Postal::Config.dns.custom_return_path_prefix}.example.com"
          expect(client.handle("RCPT TO: #{address}")).to eq "250 OK"
          expect(client.recipients).to eq [[:bounce, address, server]]
          expect(client.state).to eq :rcpt_to_received
        end
      end

      context "when the RCPT TO address is within the route domain" do
        it "returns an error if the route token is invalid" do
          address = "nothing@#{Postal::Config.dns.route_domain}"
          expect(client.handle("RCPT TO: #{address}")).to eq "550 Invalid route token"
        end

        it "returns an error if the server is suspended" do
          server = create(:server, :suspended)
          route = create(:route, server: server)
          address = "#{route.token}@#{Postal::Config.dns.route_domain}"
          expect(client.handle("RCPT TO: #{address}")).to eq "535 Mail server has been suspended"
        end

        it "returns an error if the route is set to Reject mail" do
          server = create(:server)
          route = create(:route, server: server, mode: "Reject")
          address = "#{route.token}@#{Postal::Config.dns.route_domain}"
          expect(client.handle("RCPT TO: #{address}")).to eq "550 Route does not accept incoming messages"
        end

        it "adds a recipient if all OK" do
          server = create(:server)
          route = create(:route, server: server)
          address = "#{route.token}+tag1@#{Postal::Config.dns.route_domain}"
          expect(client.handle("RCPT TO: #{address}")).to eq "250 OK"
          expect(client.recipients).to eq [[:route, "#{route.name}+tag1@#{route.domain.name}", server, { route: route }]]
          expect(client.state).to eq :rcpt_to_received
        end
      end

      context "when authenticated and the RCPT TO address is provided" do
        it "returns an error if the server is suspended" do
          server = create(:server, :suspended)
          credential = create(:credential, server: server, type: "SMTP")
          expect(client.handle("AUTH PLAIN #{credential.to_smtp_plain}")).to match(/235 Granted for /)
          expect(client.handle("RCPT TO: outgoing@example.com")).to eq "535 Mail server has been suspended"
        end

        it "adds a recipient if all OK" do
          server = create(:server)
          credential = create(:credential, server: server, type: "SMTP")
          expect(client.handle("AUTH PLAIN #{credential.to_smtp_plain}")).to match(/235 Granted for /)
          expect(client.handle("RCPT TO: outgoing@example.com")).to eq "250 OK"
          expect(client.recipients).to eq [[:credential, "outgoing@example.com", server]]
          expect(client.state).to eq :rcpt_to_received
        end
      end

      context "when not authenticated and the RCPT TO address is a route" do
        it "returns an error if the server is suspended" do
          server = create(:server, :suspended)
          route = create(:route, server: server)
          address = "#{route.name}@#{route.domain.name}"
          expect(client.handle("RCPT TO: #{address}")).to eq "535 Mail server has been suspended"
        end

        it "returns an error if the route is set to Reject mail" do
          server = create(:server)
          route = create(:route, server: server, mode: "Reject")
          address = "#{route.name}@#{route.domain.name}"
          expect(client.handle("RCPT TO: #{address}")).to eq "550 Route does not accept incoming messages"
        end

        it "adds a recipient if all OK" do
          server = create(:server)
          route = create(:route, server: server)
          address = "#{route.name}@#{route.domain.name}"
          expect(client.handle("RCPT TO: #{address}")).to eq "250 OK"
          expect(client.recipients).to eq [[:route, address, server, { route: route }]]
          expect(client.state).to eq :rcpt_to_received
        end
      end

      context "when not authenticated and RCPT TO does not match a route" do
        it "returns an error" do
          expect(client.handle("RCPT TO: nothing@nothing.com")).to eq "530 Authentication required"
        end

        context "when the connecting IP has an credential" do
          it "adds a recipient" do
            server = create(:server)
            create(:credential, server: server, type: "SMTP-IP", key: "1.0.0.0/8")
            address = "test@example.com"
            expect(client.handle("RCPT TO: #{address}")).to eq "250 OK"
            expect(client.recipients).to eq [[:credential, address, server]]
            expect(client.state).to eq :rcpt_to_received
          end
        end
      end
    end
  end

end
