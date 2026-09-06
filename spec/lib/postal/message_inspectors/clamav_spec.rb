# frozen_string_literal: true

require "rails_helper"

RSpec.describe Postal::MessageInspectors::Clamav do
  let(:config) { Postal::Config.clamav }
  let(:inspector) { described_class.new(config) }
  let(:raw_message) { "From: a@example.com\r\nSubject: Hi\r\n\r\nHello world!\r\n" }
  let(:message) { instance_double(Postal::MessageDB::Message, raw_message: raw_message) }
  let(:inspection) { Postal::MessageInspection.new(message, :incoming) }
  let(:socket) { instance_double(TCPSocket, write: nil, close_write: nil, close: nil, read: response) }
  let(:response) { "stream: OK\0" }

  before do
    allow(TCPSocket).to receive(:new).with(config.host, config.port).and_return(socket)
    inspector.inspect_message(inspection)
  end

  describe "the clamd request" do
    it "streams the message using the INSTREAM protocol" do
      expect(socket).to have_received(:write).with("zINSTREAM\0").ordered
      expect(socket).to have_received(:write).with([raw_message.bytesize].pack("N")).ordered
      expect(socket).to have_received(:write).with(raw_message).ordered
      expect(socket).to have_received(:write).with([0].pack("N")).ordered
      expect(socket).to have_received(:close_write)
    end

    it "closes the socket" do
      expect(socket).to have_received(:close)
    end
  end

  describe "parsing the response" do
    context "when clamd reports OK" do
      it "reports no threat" do
        expect(inspection.threat).to be false
        expect(inspection.threat_message).to eq "No threats found"
      end
    end

    context "when clamd reports OK in lower case" do
      let(:response) { "stream: ok\0" }

      it "reports no threat" do
        expect(inspection.threat).to be false
        expect(inspection.threat_message).to eq "No threats found"
      end
    end

    context "when clamd reports OK followed by a newline" do
      let(:response) { "stream: OK\n" }

      it "reports no threat" do
        expect(inspection.threat).to be false
        expect(inspection.threat_message).to eq "No threats found"
      end
    end

    context "when clamd finds a virus" do
      let(:response) { "stream: Eicar-Test-Signature FOUND\0" }

      it "reports the threat" do
        expect(inspection.threat).to be true
      end

      it "uses the signature name as the threat message" do
        expect(inspection.threat_message).to eq "Eicar-Test-Signature"
      end
    end

    context "when the signature name contains dots, underscores and digits" do
      let(:response) { "stream: Win.Test.EICAR_HDB-1 FOUND\0" }

      it "uses the whole signature name" do
        expect(inspection.threat).to be true
        expect(inspection.threat_message).to eq "Win.Test.EICAR_HDB-1"
      end
    end

    context "when clamd finds a virus and terminates with a newline" do
      let(:response) { "stream: Eicar-Test-Signature FOUND\n" }

      it "reports the threat" do
        expect(inspection.threat).to be true
        expect(inspection.threat_message).to eq "Eicar-Test-Signature"
      end
    end

    context "when clamd finds a virus and terminates with a newline and a NUL" do
      let(:response) { "stream: Eicar-Test-Signature FOUND\n\0" }

      it "reports the threat" do
        expect(inspection.threat).to be true
        expect(inspection.threat_message).to eq "Eicar-Test-Signature"
      end
    end

    context "when clamd reports an error" do
      let(:response) { "stream: INSTREAM size limit exceeded. ERROR\0" }

      it "does not report a threat" do
        expect(inspection.threat).to be false
      end
    end

    context "when there is no terminator after OK" do
      let(:response) { "stream: OK" }

      it "reports no threat" do
        expect(inspection.threat).to be false
        expect(inspection.threat_message).to eq "No threats found"
      end
    end

    context "when there is no space after the stream prefix" do
      let(:response) { "stream:OK\0" }

      it "reports that the message could not be scanned" do
        expect(inspection.threat).to be false
        expect(inspection.threat_message).to eq "Could not scan message"
      end
    end

    context "when the response does not start with the stream prefix" do
      let(:response) { "UNKNOWN COMMAND\0" }

      it "reports that the message could not be scanned" do
        expect(inspection.threat).to be false
        expect(inspection.threat_message).to eq "Could not scan message"
      end
    end

    context "when the stream prefix is not at the start of the response" do
      let(:response) { "x stream: Eicar-Test-Signature FOUND\0" }

      it "reports that the message could not be scanned" do
        expect(inspection.threat).to be false
        expect(inspection.threat_message).to eq "Could not scan message"
      end
    end

    context "when the response is empty" do
      let(:response) { "" }

      it "reports that the message could not be scanned" do
        expect(inspection.threat).to be false
        expect(inspection.threat_message).to eq "Could not scan message"
      end
    end

    context "when the response is nil" do
      let(:response) { nil }

      it "reports that the message could not be scanned" do
        expect(inspection.threat).to be false
        expect(inspection.threat_message).to eq "Could not scan message"
      end
    end
  end

  describe "errors" do
    context "when the connection times out" do
      before do
        allow(TCPSocket).to receive(:new).and_raise(Timeout::Error)
        inspector.inspect_message(inspection)
      end

      it "reports a timeout" do
        expect(inspection.threat).to be false
        expect(inspection.threat_message).to eq "Timed out scanning for threats"
      end
    end

    context "when the connection is refused" do
      before do
        allow(TCPSocket).to receive(:new).and_raise(Errno::ECONNREFUSED)
        inspector.inspect_message(inspection)
      end

      it "reports an error" do
        expect(inspection.threat).to be false
        expect(inspection.threat_message).to eq "Error when scanning for threats"
      end
    end
  end
end
