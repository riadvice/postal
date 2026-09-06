# frozen_string_literal: true

require "rails_helper"

module SMTPServer

  describe Client do
    let(:ip_address) { "1.2.3.4" }
    subject(:client) { described_class.new(ip_address) }

    describe "MAIL FROM" do
      it "returns an error if no HELO is provided" do
        expect(client.handle("MAIL FROM: test@example.com")).to eq "503 EHLO/HELO first please"
        expect(client.state).to eq :welcome
      end

      it "resets the transaction when called" do
        expect(client).to receive(:transaction_reset).and_call_original.at_least(3).times
        client.handle("HELO test.example.com")
        client.handle("MAIL FROM: test@example.com")
        client.handle("MAIL FROM: test2@example.com")
      end

      it "sets the mail from address" do
        client.handle("HELO test.example.com")
        expect(client.handle("MAIL FROM: test@example.com")).to eq "250 OK"
        expect(client.state).to eq :mail_from_received
        expect(client.instance_variable_get("@mail_from")).to eq "test@example.com"
      end

      describe "address extraction" do
        before do
          client.handle("HELO test.example.com")
        end

        def mail_from(line)
          expect(client.handle(line)).to eq "250 OK"
          client.instance_variable_get("@mail_from")
        end

        it "extracts an address in angle brackets" do
          expect(mail_from("MAIL FROM:<test@example.com>")).to eq "test@example.com"
        end

        it "extracts an address in angle brackets after a space" do
          expect(mail_from("MAIL FROM: <test@example.com>")).to eq "test@example.com"
        end

        it "extracts an address with spaces around the colon" do
          expect(mail_from("MAIL FROM : <test@example.com>")).to eq "test@example.com"
          expect(mail_from("MAIL FROM :<test@example.com>")).to eq "test@example.com"
          expect(mail_from("MAIL FROM\t:\t<test@example.com>")).to eq "test@example.com"
        end

        it "extracts an address with many spaces after the colon" do
          expect(mail_from("MAIL FROM:     <test@example.com>")).to eq "test@example.com"
        end

        it "extracts an address without angle brackets" do
          expect(mail_from("MAIL FROM: test@example.com")).to eq "test@example.com"
          expect(mail_from("MAIL FROM:test@example.com")).to eq "test@example.com"
        end

        it "extracts an address without a colon" do
          expect(mail_from("MAIL FROM <test@example.com>")).to eq "test@example.com"
        end

        it "extracts an address when the command is lowercase" do
          expect(mail_from("mail from:<test@example.com>")).to eq "test@example.com"
          expect(mail_from("Mail From: <test@example.com>")).to eq "test@example.com"
        end

        it "strips whitespace around the address" do
          expect(mail_from("MAIL FROM:< test@example.com >")).to eq "test@example.com"
          expect(mail_from("MAIL FROM: test@example.com   ")).to eq "test@example.com"
          expect(mail_from("MAIL FROM:<test@example.com>\r")).to eq "test@example.com"
        end

        it "extracts a null sender" do
          expect(mail_from("MAIL FROM:<>")).to eq ""
          expect(mail_from("MAIL FROM: <>")).to eq ""
        end

        it "extracts an empty sender" do
          expect(mail_from("MAIL FROM:")).to eq ""
          expect(mail_from("MAIL FROM: ")).to eq ""
        end

        it "extracts an empty sender when the colon is missing" do
          expect(mail_from("MAIL FROM")).to eq ""
        end

        it "extracts an address with a plus tag" do
          expect(mail_from("MAIL FROM:<test+tag@example.com>")).to eq "test+tag@example.com"
          expect(mail_from("MAIL FROM:<test+a+b@example.com>")).to eq "test+a+b@example.com"
        end

        it "extracts an address with a quoted local part" do
          expect(mail_from("MAIL FROM:<\"john doe\"@example.com>")).to eq "\"john doe\"@example.com"
          expect(mail_from("MAIL FROM:<\"a:b\"@example.com>")).to eq "\"a:b\"@example.com"
        end

        it "extracts an address with dots and dashes" do
          expect(mail_from("MAIL FROM:<first.last-name@sub.example-domain.com>")).to eq "first.last-name@sub.example-domain.com"
        end

        it "extracts a unicode address" do
          expect(mail_from("MAIL FROM:<jöhn@exämple.com>")).to eq "jöhn@exämple.com"
          expect(mail_from("MAIL FROM:<用户@例子.广告>")).to eq "用户@例子.广告"
        end

        it "extracts an address with an IP literal domain" do
          expect(mail_from("MAIL FROM:<test@[1.2.3.4]>")).to eq "test@[1.2.3.4]"
        end

        it "extracts a very long address" do
          address = "#{'a' * 5000}@#{'b' * 5000}.com"
          expect(mail_from("MAIL FROM:<#{address}>")).to eq address
        end

        it "preserves the case of the address" do
          expect(mail_from("MAIL FROM:<Test@Example.COM>")).to eq "Test@Example.COM"
        end

        it "extracts an address with a source route" do
          expect(mail_from("MAIL FROM:<@relay.example.com:test@example.com>")).to eq "@relay.example.com:test@example.com"
        end

        it "extracts an address containing the words mail from" do
          expect(mail_from("MAIL FROM:<mail.from@example.com>")).to eq "mail.from@example.com"
        end

        it "keeps bracket content that looks like a command" do
          expect(mail_from("MAIL FROM:<MAIL FROM:test@example.com>")).to eq "MAIL FROM:test@example.com"
        end

        context "with parameters" do
          it "discards SIZE" do
            expect(mail_from("MAIL FROM:<test@example.com> SIZE=1000")).to eq "test@example.com"
          end

          it "discards multiple parameters" do
            expect(mail_from("MAIL FROM:<test@example.com> SIZE=1000 BODY=8BITMIME SMTPUTF8")).to eq "test@example.com"
          end

          it "discards parameters directly after the bracket" do
            expect(mail_from("MAIL FROM:<test@example.com>SIZE=1000")).to eq "test@example.com"
          end

          it "discards an AUTH parameter" do
            expect(mail_from("MAIL FROM:<test@example.com> AUTH=<>")).to eq "test@example.com"
          end

          it "discards an AUTH parameter with a value" do
            expect(mail_from("MAIL FROM:<test@example.com> AUTH=someone@example.com")).to eq "test@example.com"
            expect(mail_from("MAIL FROM:<test@example.com> AUTH=<someone@example.com>")).to eq "test@example.com"
          end

          it "discards an AUTH parameter between other parameters" do
            expect(mail_from("MAIL FROM:<test@example.com> SIZE=1000 AUTH=<> BODY=8BITMIME")).to eq "test@example.com"
          end

          it "discards an AUTH parameter without angle brackets around the address" do
            expect(mail_from("MAIL FROM: test@example.com AUTH=<>")).to eq "test@example.com"
          end

          it "discards an AUTH parameter followed by another angle bracket address" do
            expect(mail_from("MAIL FROM:<test@example.com> AUTH=<other@example.com> X=<y>")).to eq "test@example.com"
          end

          it "discards parameters that contain angle brackets" do
            expect(mail_from("MAIL FROM:<test@example.com> ENVID=<abc>")).to eq "test@example.com"
          end

          it "discards a lowercase AUTH parameter" do
            expect(mail_from("MAIL FROM:<test@example.com> auth=<>")).to eq "test@example.com"
          end

          it "discards parameters when the address has no angle brackets" do
            expect(mail_from("MAIL FROM: test@example.com SIZE=1000")).to eq "test@example.com"
          end
        end

        context "with malformed brackets" do
          it "handles a missing closing bracket" do
            expect(mail_from("MAIL FROM:<test@example.com")).to eq "test@example.com"
          end

          it "handles a missing opening bracket" do
            expect(mail_from("MAIL FROM: test@example.com>")).to eq "test@example.com"
          end

          it "handles doubled brackets" do
            expect(mail_from("MAIL FROM:<<test@example.com>>")).to eq "test@example.com"
          end

          it "handles a trailing extra bracket" do
            expect(mail_from("MAIL FROM:<test@example.com>>")).to eq "test@example.com"
          end

          it "uses the text after the last opening bracket" do
            expect(mail_from("MAIL FROM:<a<test@example.com>")).to eq "test@example.com"
            expect(mail_from("MAIL FROM:<a@b.com> <test@example.com>")).to eq "a@b.com"
          end

          it "uses the text before the first closing bracket" do
            expect(mail_from("MAIL FROM:<test@example.com>b>")).to eq "test@example.com"
          end

          it "extracts nothing when only brackets are sent" do
            expect(mail_from("MAIL FROM:<><>")).to eq ""
            expect(mail_from("MAIL FROM:><")).to eq ""
          end
        end

        context "with control characters" do
          it "strips a carriage return in the middle of the line" do
            expect(mail_from("MAIL FROM:<test@example.com>\rQUIT")).to eq "test@example.com"
          end

          it "strips a null byte after the address" do
            expect(mail_from("MAIL FROM:<test@example.com>\0")).to eq "test@example.com"
          end

          it "does not allow a line feed to smuggle a second address" do
            expect(mail_from("MAIL FROM:<test@example.com>\r\nRCPT TO:<other@example.com>")).to eq "test@example.com"
          end
        end
      end
    end
  end

end
