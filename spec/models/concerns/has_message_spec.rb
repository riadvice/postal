# frozen_string_literal: true

require "rails_helper"

RSpec.describe HasMessage do
  describe ".include_message" do
    it "returns an empty array when there are no queued messages" do
      expect(QueuedMessage.where(id: -1).include_message).to eq []
    end

    it "raises when the queued messages belong to more than one server" do
      create(:queued_message)
      create(:queued_message)
      expect { QueuedMessage.all.include_message }.to raise_error(Postal::Error, /same server/)
    end

    it "attaches the backend message to each queued message" do
      server = create(:server)
      message = MessageFactory.incoming(server)
      queued_message = create(:queued_message, message: message)
      result = server.queued_messages.include_message
      expect(result.map(&:id)).to eq [queued_message.id]
      expect(result.first.message.id).to eq message.id
    end
  end

  describe "#message" do
    it "returns nil when the backend message no longer exists" do
      queued_message = create(:queued_message, message_id: 999_999_999)
      expect(queued_message.message).to be_nil
    end
  end
end
