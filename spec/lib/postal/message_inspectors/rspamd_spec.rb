# frozen_string_literal: true

require "rails_helper"

RSpec.describe Postal::MessageInspectors::Rspamd do
  let(:config) { Postal::Config.rspamd }
  let(:inspector) { described_class.new(config) }
  let(:raw_message) { "From: a@example.com\r\nSubject: Hi\r\n\r\nHello world!\r\n" }
  let(:message) { double("Message", raw_message: raw_message, rcpt_to: "to@example.com", mail_from: "from@example.com", token: "abcdef1234567890") }
  let(:scope) { :incoming }
  let(:inspection) { Postal::MessageInspection.new(message, scope) }
  let(:url) { "http://#{config.host}:#{config.port}/checkv2" }
  let(:status) { 200 }
  let(:body) do
    {
      "is_skipped" => false,
      "score" => 7.5,
      "required_score" => 15,
      "action" => "add header",
      "symbols" => {
        "MIME_GOOD" => { "name" => "MIME_GOOD", "score" => -0.1, "metric_score" => -0.1, "description" => "Known content-type", "options" => ["multipart/alternative", "text/plain"] },
        "ARC_NA" => { "name" => "ARC_NA", "score" => 0, "metric_score" => 0, "description" => "ARC signature absent" },
        "R_DKIM_NA" => { "name" => "R_DKIM_NA", "score" => 0.0, "metric_score" => 0.0, "description" => "Missing DKIM signature" },
        "BAYES_SPAM" => { "name" => "BAYES_SPAM", "score" => 5.1, "metric_score" => 5.1, "description" => "Bayes: spam", "options" => ["99.99%"] },
        "MISSING_MID" => { "name" => "MISSING_MID", "score" => 2.5, "metric_score" => 2.5, "description" => "Message id is missing" },
        "RCVD_COUNT_ZERO" => { "name" => "RCVD_COUNT_ZERO", "score" => 0, "metric_score" => 0, "options" => ["0"] },
        "BLANK_DESCRIPTION" => { "name" => "BLANK_DESCRIPTION", "score" => 1, "description" => "" },
        "NIL_DESCRIPTION" => { "name" => "NIL_DESCRIPTION", "score" => 1, "description" => nil }
      },
      "messages" => {}
    }.to_json
  end

  before do
    stub_request(:post, url).to_return(status: status, body: body)
  end

  let(:checks) do
    inspector.inspect_message(inspection)
    inspection.spam_checks
  end

  def check(code)
    checks.find { |c| c.code == code }
  end

  describe "the rspamd request" do
    it "posts the raw message with the message details as headers" do
      checks
      expect(a_request(:post, url).with(body: raw_message, headers: {
        "Content-Length" => raw_message.bytesize.to_s,
        "User-Agent" => "Postal",
        "Deliver-To" => "to@example.com",
        "From" => "from@example.com",
        "Rcpt" => "to@example.com",
        "Queue-Id" => "abcdef1234567890"
      })).to have_been_made.once
    end

    it "does not send the outbound headers for incoming messages" do
      checks
      expect(a_request(:post, url).with { |req| req.headers.key?("User") || req.headers.key?("Ip") }).not_to have_been_made
    end

    context "for outgoing messages" do
      let(:scope) { :outgoing }

      it "sends empty User and Ip headers" do
        checks
        expect(a_request(:post, url).with(headers: { "User" => "", "Ip" => "" })).to have_been_made.once
      end
    end
  end

  describe "parsing the response" do
    it "creates a check for each symbol with a description" do
      expect(checks.map(&:code)).to contain_exactly("MIME_GOOD", "ARC_NA", "R_DKIM_NA", "BAYES_SPAM", "MISSING_MID")
    end

    it "uses the symbol score" do
      expect(check("MIME_GOOD").score).to eq(-0.1)
      expect(check("ARC_NA").score).to eq 0
      expect(check("BAYES_SPAM").score).to eq 5.1
      expect(check("MISSING_MID").score).to eq 2.5
    end

    it "uses the symbol description" do
      expect(check("MIME_GOOD").description).to eq "Known content-type"
      expect(check("BAYES_SPAM").description).to eq "Bayes: spam"
    end

    it "skips symbols without a description" do
      expect(check("RCVD_COUNT_ZERO")).to be_nil
      expect(check("BLANK_DESCRIPTION")).to be_nil
      expect(check("NIL_DESCRIPTION")).to be_nil
    end

    it "sums the scores into the spam score" do
      checks
      expect(inspection.spam_score).to be_within(0.001).of(7.5)
    end

    context "when there are no symbols" do
      let(:body) { { "score" => 0, "symbols" => {} }.to_json }

      it "adds no checks" do
        expect(checks).to eq []
      end
    end

    context "when the symbols key is missing" do
      let(:body) { { "score" => 0 }.to_json }

      it "adds no checks" do
        expect(checks).to eq []
      end
    end

    context "when the symbols key is not a hash" do
      let(:body) { { "score" => 0, "symbols" => ["MIME_GOOD"] }.to_json }

      it "adds no checks" do
        expect(checks).to eq []
      end
    end

    context "when a symbol has no score" do
      let(:body) { { "symbols" => { "ODD" => { "name" => "ODD", "description" => "No score given" } } }.to_json }

      it "counts it as zero" do
        expect(check("ODD").score).to eq 0.0
        expect(inspection.spam_score).to eq 0.0
      end
    end

    context "when the body is not JSON" do
      let(:body) { "<html><body>502 Bad Gateway</body></html>" }

      it "adds an ERROR check instead of raising" do
        expect(checks.map(&:code)).to eq ["ERROR"]
        expect(checks.first.description).to eq "Error when scanning with rspamd (invalid response)"
      end
    end
  end

  describe "errors" do
    context "when rspamd returns a non-200 status" do
      let(:status) { 500 }

      it "adds an ERROR check" do
        expect(checks.map(&:code)).to eq ["ERROR"]
        expect(checks.first.score).to eq 0
        expect(checks.first.description).to eq "Error when scanning with rspamd (got 500)"
      end
    end

    context "when rspamd returns a 403" do
      let(:status) { 403 }

      it "adds an ERROR check with the status" do
        expect(checks.first.description).to eq "Error when scanning with rspamd (got 403)"
      end
    end

    context "when the connection fails" do
      before do
        stub_request(:post, url).to_raise(Errno::ECONNREFUSED)
      end

      it "adds an ERROR check" do
        expect(checks.map(&:code)).to eq ["ERROR"]
        expect(checks.first.description).to eq "Error when scanning with rspamd (Errno::ECONNREFUSED)"
      end
    end

    context "when the connection times out" do
      before do
        stub_request(:post, url).to_timeout
      end

      it "adds an ERROR check" do
        expect(checks.map(&:code)).to eq ["ERROR"]
        expect(checks.first.description).to match(/\AError when scanning with rspamd \(.*Timeout.*\)\z/)
      end
    end
  end
end
