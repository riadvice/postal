# frozen_string_literal: true

require "rails_helper"

module SMTPServer

  describe Client do
    let(:ip_address) { "1.2.3.4" }
    subject(:client) { described_class.new(ip_address) }

    describe "DATA" do
      it "returns an error if no helo" do
        expect(client.handle("DATA")).to eq "503 HELO/EHLO, MAIL FROM and RCPT TO before sending data"
      end

      it "returns an error if no mail from" do
        client.handle("HELO test.example.com")
        expect(client.handle("DATA")).to eq "503 HELO/EHLO, MAIL FROM and RCPT TO before sending data"
      end

      it "returns an error if no rcpt to" do
        client.handle("HELO test.example.com")
        client.handle("MAIL FROM: test@example.com")
        expect(client.handle("DATA")).to eq "503 HELO/EHLO, MAIL FROM and RCPT TO before sending data"
      end

      it "returns go ahead" do
        route = create(:route)
        client.handle("HELO test.example.com")
        client.handle("MAIL FROM: test@test.com")
        client.handle("RCPT TO: #{route.name}@#{route.domain.name}")
        expect(client.handle("DATA")).to eq "354 Go ahead"
      end

      it "adds a received header for itself" do
        route = create(:route)
        client.handle("HELO test.example.com")
        client.handle("MAIL FROM: test@test.com")
        client.handle("RCPT TO: #{route.name}@#{route.domain.name}")
        Timecop.freeze do
          client.handle("DATA")
          expect(client.headers["received"]).to include "from test.example.com (1.2.3.4 [1.2.3.4]) by #{Postal::Config.postal.smtp_hostname} with SMTP; #{Time.now.utc.rfc2822}"
        end
      end

      describe "subsequent commands" do
        let(:route) { create(:route) }
        before do
          client.handle("HELO test.example.com")
          client.handle("MAIL FROM: test@test.com")
          client.handle("RCPT TO: #{route.name}@#{route.domain.name}")
        end

        it "logs headers" do
          client.handle("DATA")
          client.handle("Subject: Test")
          client.handle("From: test@test.com")
          client.handle("To: test1@example.com")
          client.handle("To: test2@example.com")
          client.handle("X-Something: abcdef1234")
          client.handle("X-Multiline: 1234")
          client.handle("             4567")
          expect(client.headers["subject"]).to eq ["Test"]
          expect(client.headers["from"]).to eq ["test@test.com"]
          expect(client.headers["to"]).to eq ["test1@example.com", "test2@example.com"]
          expect(client.headers["x-something"]).to eq ["abcdef1234"]
          expect(client.headers["x-multiline"]).to eq ["1234             4567"]
        end

        it "logs content" do
          Timecop.freeze do
            client.handle("DATA")
            client.handle("Subject: Test")
            client.handle("")
            client.handle("This is some content for the message.")
            client.handle("It will keep going.")
            expect(client.instance_variable_get("@data")).to eq <<~DATA
              Received: from test.example.com (1.2.3.4 [1.2.3.4]) by #{Postal::Config.postal.smtp_hostname} with SMTP; #{Time.now.utc.rfc2822}\r
              Subject: Test\r
              \r
              This is some content for the message.\r
              It will keep going.\r
            DATA
          end
        end

        def body
          client.instance_variable_get("@data").split("\r\n", 2)[1]
        end

        describe "header parsing" do
          before do
            client.handle("DATA")
          end

          it "returns nil for each line" do
            expect(client.handle("Subject: Test")).to be_nil
            expect(client.handle("")).to be_nil
            expect(client.handle("body")).to be_nil
          end

          it "downcases the header key" do
            client.handle("SUBJECT: Test")
            client.handle("X-Mixed-Case: Value")
            expect(client.headers["subject"]).to eq ["Test"]
            expect(client.headers["x-mixed-case"]).to eq ["Value"]
            expect(client.headers).not_to have_key "SUBJECT"
          end

          it "preserves the case of the value" do
            client.handle("Subject: Hello World")
            expect(client.headers["subject"]).to eq ["Hello World"]
          end

          it "accepts no space after the colon" do
            client.handle("Subject:Test")
            expect(client.headers["subject"]).to eq ["Test"]
          end

          it "strips all whitespace after the colon" do
            client.handle("Subject:      Test")
            client.handle("X-Tab:\tTest")
            client.handle("X-Mixed: \t Test")
            expect(client.headers["subject"]).to eq ["Test"]
            expect(client.headers["x-tab"]).to eq ["Test"]
            expect(client.headers["x-mixed"]).to eq ["Test"]
          end

          it "keeps trailing whitespace in the value" do
            client.handle("Subject: Test   ")
            expect(client.headers["subject"]).to eq ["Test   "]
          end

          it "keeps whitespace before the colon in the key" do
            client.handle("Subject : Test")
            expect(client.headers["subject "]).to eq ["Test"]
          end

          it "only splits on the first colon" do
            client.handle("Subject: Re: a: b")
            client.handle("X-Url: http://example.com:8080/")
            expect(client.headers["subject"]).to eq ["Re: a: b"]
            expect(client.headers["x-url"]).to eq ["http://example.com:8080/"]
          end

          it "keeps a colon immediately following the first" do
            client.handle("X-Test::value")
            expect(client.headers["x-test"]).to eq [":value"]
          end

          it "stores an empty value for a header with no value" do
            client.handle("Subject:")
            client.handle("X-Empty: ")
            expect(client.headers["subject"]).to eq [""]
            expect(client.headers["x-empty"]).to eq [""]
          end

          it "stores a nil value for a line with no colon" do
            client.handle("NotAHeader")
            expect(client.headers["notaheader"]).to eq [nil]
          end

          it "stores a unicode value" do
            client.handle("Subject: Grüße 你好")
            expect(client.headers["subject"]).to eq ["Grüße 你好"]
          end

          it "stores a very long value" do
            client.handle("Subject: #{'a' * 100_000}")
            expect(client.headers["subject"]).to eq ["a" * 100_000]
          end

          it "collects repeated headers in order" do
            client.handle("Received: one")
            client.handle("Received: two")
            expect(client.headers["received"].last(2)).to eq ["one", "two"]
          end

          it "appends a continuation line starting with a space" do
            client.handle("Subject: Test")
            client.handle(" continued")
            expect(client.headers["subject"]).to eq ["Test continued"]
          end

          it "appends a continuation line starting with a tab" do
            client.handle("Subject: Test")
            client.handle("\tcontinued")
            expect(client.headers["subject"]).to eq ["Test\tcontinued"]
          end

          it "appends multiple continuation lines" do
            client.handle("Subject: One")
            client.handle(" Two")
            client.handle(" Three")
            expect(client.headers["subject"]).to eq ["One Two Three"]
          end

          it "appends the continuation to the most recent value of the header" do
            client.handle("To: first@example.com")
            client.handle("To: second@example.com")
            client.handle(" continued")
            expect(client.headers["to"]).to eq ["first@example.com", "second@example.com continued"]
          end

          it "appends a continuation containing a colon" do
            client.handle("Subject: Test")
            client.handle(" Re: something")
            expect(client.headers["subject"]).to eq ["Test Re: something"]
            expect(client.headers).not_to have_key " re"
          end

          it "ignores a continuation line before any header" do
            client.handle(" orphan")
            expect(client.headers.keys).to eq ["received"]
            expect(body).to eq " orphan\r\n"
          end

          it "does not append a continuation to a header with a nil value" do
            client.handle("NotAHeader")
            client.handle(" continued")
            expect(client.headers["notaheader"]).to eq [nil]
          end

          it "does not treat a line with only whitespace as the end of the headers" do
            client.handle("Subject: Test")
            client.handle(" ")
            client.handle("X-After: yes")
            expect(client.headers["subject"]).to eq ["Test "]
            expect(client.headers["x-after"]).to eq ["yes"]
          end

          it "stops parsing headers at the first empty line" do
            client.handle("Subject: Test")
            client.handle("")
            client.handle("X-Body: not a header")
            client.handle(" continuation")
            expect(client.headers["subject"]).to eq ["Test"]
            expect(client.headers).not_to have_key "x-body"
          end

          it "stops parsing headers at an empty line with a trailing <CR>" do
            client.handle("Subject: Test\r")
            client.handle("\r")
            client.handle("X-Body: not a header\r")
            expect(client.headers["subject"]).to eq ["Test"]
            expect(client.headers).not_to have_key "x-body"
          end

          it "removes dot stuffing from a header line" do
            client.handle("..X-Dot: value")
            expect(client.headers[".x-dot"]).to eq ["value"]
          end

          it "still records body lines in the data" do
            client.handle("Subject: Test")
            client.handle("")
            client.handle("X-Body: line")
            expect(body).to eq "Subject: Test\r\n\r\nX-Body: line\r\n"
          end
        end

        describe "dot stuffing" do
          before do
            client.handle("DATA")
            client.handle("")
          end

          it "removes the first dot from a line starting with two dots" do
            client.handle("..")
            client.handle("..dot")
            client.handle("...three")
            client.handle("....four")
            expect(body).to eq "\r\n.\r\n.dot\r\n..three\r\n...four\r\n"
          end

          it "does not change a line starting with a single dot" do
            client.handle(".dot")
            client.handle(". dot")
            expect(body).to eq "\r\n.dot\r\n. dot\r\n"
          end

          it "does not change dots that are not at the start of the line" do
            client.handle("a..b")
            client.handle(" ..b")
            client.handle("end..")
            expect(body).to eq "\r\na..b\r\n ..b\r\nend..\r\n"
          end

          it "removes the first dot from a line with a trailing <CR>" do
            client.handle("..dot\r")
            expect(body).to eq "\r\n.dot\r\n"
          end

          it "does not end the message with a single dot without a <CR>" do
            expect(client.handle(".")).to be_nil
            expect(body).to eq "\r\n.\r\n"
            expect(client.state).to eq :rcpt_to_received
          end

          it "does not end the message with a single dot when the previous line had no <CR>" do
            expect(client.handle(".\r")).to be_nil
            expect(body).to eq "\r\n.\r\n"
            expect(client.state).to eq :rcpt_to_received
          end

          it "does not end the message with a dot followed by text" do
            client.handle("body\r")
            expect(client.handle(". \r")).to be_nil
            expect(client.handle(".x\r")).to be_nil
            expect(body).to eq "\r\nbody\r\n. \r\n.x\r\n"
          end

          it "ends the message with a single dot after a line ending with <CR>" do
            client.handle("body\r")
            expect(client.handle(".\r")).to eq "250 OK"
            expect(client.state).to eq :welcomed
          end

          it "ends the message when the previous line was empty with a <CR>" do
            client.handle("\r")
            expect(client.handle(".\r")).to eq "250 OK"
          end
        end
      end
    end
  end

end
