# frozen_string_literal: true

require "rails_helper"

RSpec.describe Postal::MessageInspectors::SpamAssassin do
  let(:config) { Postal::Config.spamd }
  let(:inspector) { described_class.new(config) }
  let(:raw_message) { "From: a@example.com\r\nSubject: Hi\r\n\r\nHello world!\r\n" }
  let(:message) { instance_double(Postal::MessageDB::Message, raw_message: raw_message) }
  let(:scope) { :incoming }
  let(:inspection) { Postal::MessageInspection.new(message, scope) }
  let(:socket) { instance_double(TCPSocket, write: nil, close_write: nil, close: nil, read: response) }
  let(:response) { report }

  let(:report) do
    <<~REPORT
      SPAMD/1.1 0 EX_OK\r
      Content-length: 2331\r
      Spam: True ; 7.3 / 5.0\r
      \r
      Spam detection software, running on the system "mail.example.com",
      has identified this incoming email as possible spam.  The original
      message has been attached to this so you can view it or label
      similar future email.  If you have any questions, see
      @@CONTACT_ADDRESS@@ for details.

      Content preview:  Hello world! [...]
       9.9 PREAMBLE_RULE          Not a real rule

      Content analysis details:   (7.3 points, 5.0 required)

       pts rule name              description
      ---- ---------------------- --------------------------------------------------
      -0.0 NO_RELAYS              Informational: message was not relayed via SMTP
       0.1 MISSING_MID            Missing Message-Id: header
       1.2 MISSING_HEADERS        Missing To: header
       0.0 HTML_MESSAGE           BODY: HTML included in message
       2.5 URIBL_DBL_SPAM         Contains a spam URL listed in the Spamhaus DBL
                                  blocklist
                                  [URIs: example.com]
      -1.9 BAYES_00               BODY: Bayes spam probability is 0 to 1%
                                  [score: 0.0000]
       3.4 RCVD_IN_SBL            RBL: Received via a relay in Spamhaus SBL
    REPORT
  end

  before do
    allow(TCPSocket).to receive(:new).with(config.host, config.port).and_return(socket)
  end

  let(:checks) do
    inspector.inspect_message(inspection)
    inspection.spam_checks
  end

  def check(code)
    checks.find { |c| c.code == code }
  end

  describe "the spamd request" do
    it "sends the REPORT command, content length and message" do
      checks
      expect(socket).to have_received(:write).with("REPORT SPAMC/1.2\r\n").ordered
      expect(socket).to have_received(:write).with("Content-length: #{raw_message.bytesize}\r\n").ordered
      expect(socket).to have_received(:write).with("\r\n").ordered
      expect(socket).to have_received(:write).with(raw_message).ordered
      expect(socket).to have_received(:close_write)
    end

    it "closes the socket" do
      checks
      expect(socket).to have_received(:close)
    end
  end

  describe "parsing the report" do
    it "creates a check for each rule line" do
      expect(checks.map(&:code)).to eq %w[NO_RELAYS MISSING_MID MISSING_HEADERS HTML_MESSAGE URIBL_DBL_SPAM BAYES_00 RCVD_IN_SBL]
    end

    it "parses positive decimal scores" do
      expect(check("MISSING_MID").score).to eq 0.1
      expect(check("MISSING_HEADERS").score).to eq 1.2
      expect(check("URIBL_DBL_SPAM").score).to eq 2.5
    end

    it "parses negative scores" do
      expect(check("BAYES_00").score).to eq(-1.9)
    end

    it "parses zero and negative zero scores" do
      expect(check("HTML_MESSAGE").score).to eq 0.0
      expect(check("NO_RELAYS").score).to eq 0.0
    end

    it "parses the description" do
      expect(check("NO_RELAYS").description).to eq "Informational: message was not relayed via SMTP"
      expect(check("MISSING_MID").description).to eq "Missing Message-Id: header"
    end

    it "appends continuation lines to the description of the previous rule" do
      expect(check("URIBL_DBL_SPAM").description).to eq "Contains a spam URL listed in the Spamhaus DBL blocklist [URIs: example.com]"
      expect(check("BAYES_00").description).to eq "BODY: Bayes spam probability is 0 to 1% [score: 0.0000]"
    end

    it "ignores everything before the separator line" do
      expect(check("PREAMBLE_RULE")).to be_nil
      expect(checks.map(&:code)).not_to include("Spam", "Content")
    end

    it "sums the scores into the spam score" do
      checks
      expect(inspection.spam_score).to be_within(0.001).of(5.3)
    end

    context "when the report uses CRLF line endings" do
      let(:response) { report.gsub(/\r?\n/, "\r\n") }

      it "parses the rules" do
        expect(checks.map(&:code)).to eq %w[NO_RELAYS MISSING_MID MISSING_HEADERS HTML_MESSAGE URIBL_DBL_SPAM BAYES_00 RCVD_IN_SBL]
        expect(check("URIBL_DBL_SPAM").description).to eq "Contains a spam URL listed in the Spamhaus DBL blocklist [URIs: example.com]"
      end
    end

    context "when the report uses LF line endings only" do
      let(:response) { report.gsub("\r\n", "\n") }

      it "parses the rules" do
        expect(checks.map(&:code)).to eq %w[NO_RELAYS MISSING_MID MISSING_HEADERS HTML_MESSAGE URIBL_DBL_SPAM BAYES_00 RCVD_IN_SBL]
      end
    end

    context "when the preamble contains a line starting with dashes" do
      let(:response) do
        report.sub("Content preview:  Hello world! [...]", "Content preview:  Hello\n--- forwarded message ---\n 5.0 FAKE_RULE fake")
      end

      it "uses the rules after the last separator" do
        expect(check("FAKE_RULE")).to be_nil
        expect(checks.map(&:code)).to eq %w[NO_RELAYS MISSING_MID MISSING_HEADERS HTML_MESSAGE URIBL_DBL_SPAM BAYES_00 RCVD_IN_SBL]
      end
    end

    context "with unusual rule lines" do
      let(:response) do
        [
          "---- ---------------------- --------------------------------------------------",
          "10.0 BIG_SCORE              A score with two digits",
          "-10.0 BIG_NEGATIVE          A big negative score",
          " 0.001 TINY_SCORE           A very small score",
          " 1.0 RCVD_IN_DNSWL_HI       Rule name with digits",
          " 1.0 __HAS_X_MAILER         Rule name starting with underscores",
          " 1.0 T_SPF_HELO_TEMPERROR   Rule name starting with a single letter",
          " 1.0 lowercase_rule         Lowercase rule name",
          " 2.0 TABBED_RULE\tDescription separated by a tab",
          " 1.0 TRAILING_SPACE         Description with trailing space   ",
          " 1.0 MULTI                  Line one",
          "                            Line two",
          "                            Line three",
          "",
        ].join("\n")
      end

      it "parses two digit scores" do
        expect(check("BIG_SCORE").score).to eq 10.0
        expect(check("BIG_NEGATIVE").score).to eq(-10.0)
      end

      it "parses scores with several decimal places" do
        expect(check("TINY_SCORE").score).to eq 0.001
      end

      it "parses rule names with digits and underscores" do
        expect(check("RCVD_IN_DNSWL_HI").score).to eq 1.0
        expect(check("__HAS_X_MAILER").score).to eq 1.0
        expect(check("T_SPF_HELO_TEMPERROR").score).to eq 1.0
        expect(check("lowercase_rule").score).to eq 1.0
      end

      it "parses descriptions separated by a tab" do
        expect(check("TABBED_RULE").description).to eq "Description separated by a tab"
      end

      it "keeps trailing whitespace in the description" do
        expect(check("TRAILING_SPACE").description).to eq "Description with trailing space   "
      end

      it "appends several continuation lines" do
        expect(check("MULTI").description).to eq "Line one Line two Line three"
      end

      it "does not treat continuation lines as rules" do
        expect(checks.map(&:code)).to eq %w[BIG_SCORE BIG_NEGATIVE TINY_SCORE RCVD_IN_DNSWL_HI __HAS_X_MAILER
                                            T_SPF_HELO_TEMPERROR lowercase_rule TABBED_RULE TRAILING_SPACE MULTI]
      end
    end

    context "when a rule line has no description" do
      let(:response) do
        <<~REPORT
          ---- ---------------------- --------------------------------------------------
           1.0 FIRST_RULE             First
           1.0 NO_DESCRIPTION
           1.0 LAST_RULE              Last
        REPORT
      end

      it "creates a check with an empty description" do
        expect(checks.map(&:code)).to eq %w[FIRST_RULE NO_DESCRIPTION LAST_RULE]
      end
    end

    context "when a rule line has trailing whitespace but no description" do
      let(:response) { "---- ----\n 1.0 FIRST_RULE First\n 1.0 NO_DESCRIPTION \n" }

      it "creates a check with an empty description" do
        expect(checks.map(&:code)).to eq %w[FIRST_RULE NO_DESCRIPTION]
        expect(check("NO_DESCRIPTION").description).to eq ""
      end
    end

    context "when a rule name contains a hyphen" do
      let(:response) do
        <<~REPORT
          ---- ---------------------- --------------------------------------------------
           1.0 FIRST_RULE             First
           1.0 BAD-RULE               Should not match
        REPORT
      end

      it "does not treat the line as a rule" do
        expect(checks.map(&:code)).to eq ["FIRST_RULE"]
        expect(check("FIRST_RULE").description).to eq "First 1.0 BAD-RULE               Should not match"
      end
    end

    context "when the report has no rules after the separator" do
      let(:response) { "Content analysis details:   (0.0 points, 5.0 required)\n\n pts rule name description\n---- ---------------------- ------\n" }

      it "adds no checks" do
        expect(checks).to eq []
      end
    end

    context "when the response is empty" do
      let(:response) { "" }

      it "adds an ERROR check" do
        expect(checks.map(&:code)).to eq ["ERROR"]
        expect(checks.first.score).to eq 0
        expect(checks.first.description).to eq "Error when scanning for spam"
      end
    end

    context "when the response is nil" do
      let(:response) { nil }

      it "adds no checks" do
        expect(checks).to eq []
      end
    end

    context "when the response has no separator line" do
      let(:response) { "SPAMD/1.1 76 EX_PROTOCOL\r\n" }

      it "adds an ERROR check" do
        expect(checks.map(&:code)).to eq ["ERROR"]
      end
    end
  end

  describe "exclusions" do
    context "for incoming messages" do
      it "keeps all checks" do
        expect(checks.map(&:code)).to include("NO_RELAYS", "RCVD_IN_SBL")
      end
    end

    context "for outgoing messages" do
      let(:scope) { :outgoing }

      it "excludes checks listed by name" do
        expect(checks.map(&:code)).not_to include("NO_RELAYS")
      end

      it "keeps checks which are not excluded" do
        expect(checks.map(&:code)).to include("MISSING_MID", "BAYES_00", "URIBL_DBL_SPAM")
      end

      it "excludes checks matching an exclusion pattern" do
        expect(checks.map(&:code)).not_to include("RCVD_IN_SBL")
      end
    end
  end

  describe "errors" do
    context "when the connection times out" do
      before do
        allow(TCPSocket).to receive(:new).and_raise(Timeout::Error)
      end

      it "adds a TIMEOUT check" do
        expect(checks.map(&:code)).to eq ["TIMEOUT"]
        expect(checks.first.description).to eq "Timed out when scanning for spam"
      end
    end

    context "when the connection is refused" do
      before do
        allow(TCPSocket).to receive(:new).and_raise(Errno::ECONNREFUSED)
      end

      it "adds an ERROR check" do
        expect(checks.map(&:code)).to eq ["ERROR"]
      end
    end
  end
end
