# frozen_string_literal: true

require "rails_helper"

RSpec.describe "config/initializers/lock_timeouts" do
  let(:initializer) { Rails.root.join("config/initializers/lock_timeouts.rb") }

  it "accepts the defaults" do
    expect { load initializer }.not_to raise_error
  end

  it "refuses a lock timeout that a single delivery could outlive" do
    allow(Postal::Config.worker).to receive(:queued_message_lock_timeout).and_return(600)
    expect { load initializer }.to raise_error(/queued_message_lock_timeout must be greater than/)
  end
end
