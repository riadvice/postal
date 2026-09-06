# frozen_string_literal: true

require "rails_helper"

describe OutgoingMessagePrototype do
  let(:server) { create(:server) }
  it "should create a new message" do
    domain = create(:domain, owner: server)
    prototype = OutgoingMessagePrototype.new(server, "127.0.0.1", "TestSuite", {
      from: "test@#{domain.name}",
      to: "test@example.com",
      subject: "Test Message",
      plain_body: "A plain body!"
    })

    expect(prototype.valid?).to be true
    message = prototype.create_message("test@example.com")
    expect(message).to be_a Hash
    expect(message[:id]).to be_a Integer
    expect(message[:token]).to be_a String
  end

  describe "address lists" do
    def prototype(attributes)
      described_class.new(server, "127.0.0.1", "TestSuite", attributes)
    end

    describe "#to_addresses" do
      it "returns a single address" do
        expect(prototype(to: "a@example.com").to_addresses).to eq ["a@example.com"]
      end

      it "splits addresses on a comma followed by a space" do
        expect(prototype(to: "a@example.com, b@example.com").to_addresses).to eq ["a@example.com", "b@example.com"]
      end

      it "splits addresses on a comma with no space" do
        expect(prototype(to: "a@example.com,b@example.com").to_addresses).to eq ["a@example.com", "b@example.com"]
      end

      it "splits addresses on a comma followed by several spaces or tabs" do
        expect(prototype(to: "a@example.com,   b@example.com,\tc@example.com").to_addresses).to eq ["a@example.com", "b@example.com", "c@example.com"]
      end

      it "splits addresses on a comma followed by a newline" do
        expect(prototype(to: "a@example.com,\r\n b@example.com").to_addresses).to eq ["a@example.com", "b@example.com"]
      end

      it "does not strip whitespace before a comma" do
        expect(prototype(to: "a@example.com , b@example.com").to_addresses).to eq ["a@example.com ", "b@example.com"]
      end

      it "splits addresses with display names" do
        expect(prototype(to: "John <a@example.com>, Jane <b@example.com>").to_addresses).to eq ["John <a@example.com>", "Jane <b@example.com>"]
      end

      it "splits a quoted display name containing a comma" do
        expect(prototype(to: "\"Doe, John\" <a@example.com>").to_addresses).to eq ["\"Doe", "John\" <a@example.com>"]
      end

      it "returns an empty array for an empty string" do
        expect(prototype(to: "").to_addresses).to eq []
      end

      it "returns an empty array when there are no recipients" do
        expect(prototype({}).to_addresses).to eq []
      end

      it "returns an array unchanged" do
        expect(prototype(to: ["a@example.com", "b@example.com"]).to_addresses).to eq ["a@example.com", "b@example.com"]
      end

      it "does not split the elements of an array" do
        expect(prototype(to: ["a@example.com, b@example.com"]).to_addresses).to eq ["a@example.com, b@example.com"]
      end

      it "ignores a trailing comma" do
        expect(prototype(to: "a@example.com, ").to_addresses).to eq ["a@example.com"]
      end
    end

    describe "#cc_addresses" do
      it "splits addresses on commas" do
        expect(prototype(cc: "a@example.com, b@example.com").cc_addresses).to eq ["a@example.com", "b@example.com"]
      end

      it "returns an empty array when there are no addresses" do
        expect(prototype({}).cc_addresses).to eq []
      end
    end

    describe "#bcc_addresses" do
      it "splits addresses on commas" do
        expect(prototype(bcc: "a@example.com,b@example.com").bcc_addresses).to eq ["a@example.com", "b@example.com"]
      end

      it "returns an empty array when there are no addresses" do
        expect(prototype({}).bcc_addresses).to eq []
      end
    end

    describe "#all_addresses" do
      it "combines to, cc and bcc addresses" do
        proto = prototype(to: "a@example.com, b@example.com", cc: ["c@example.com"], bcc: "d@example.com")
        expect(proto.all_addresses).to eq ["a@example.com", "b@example.com", "c@example.com", "d@example.com"]
      end
    end

    describe "#from_address" do
      it "strips the display name" do
        expect(prototype(from: "John <john@example.com>").from_address).to eq "john@example.com"
      end

      it "returns nil when there is no from address" do
        expect(prototype({}).from_address).to be_nil
      end
    end

    describe "#sender_address" do
      it "strips the display name" do
        expect(prototype(sender: "John <john@example.com> (comment)").sender_address).to eq "john@example.com"
      end

      it "returns nil when there is no sender address" do
        expect(prototype({}).sender_address).to be_nil
      end
    end
  end
end
