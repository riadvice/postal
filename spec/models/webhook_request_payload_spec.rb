# frozen_string_literal: true

require "rails_helper"

RSpec.describe WebhookRequest do
  describe "#payload" do
    it "round-trips the types a payload can hold" do
      payload = { "at" => Time.zone.now, "on" => Date.today, "amount" => BigDecimal("1.5"), "sym" => :outgoing }
      request = create(:webhook_request, payload: payload)
      expect(request.reload.payload).to eq payload
    end
  end
end
