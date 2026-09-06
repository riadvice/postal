# frozen_string_literal: true

require "rails_helper"

RSpec.describe TidyWebhookRequestsTask do
  let(:logger) { TestLogger.new }

  subject(:task) { described_class.new(logger: logger) }

  describe "#call" do
    it "releases locks that are older than the configured stale period" do
      allow(Postal::Config.postal).to receive(:webhook_request_lock_stale_minutes).and_return(60)
      request = create(:webhook_request, :locked, locked_at: 2.hours.ago)
      task.call
      expect(request.reload).to have_attributes(locked_by: nil, locked_at: nil)
      expect(logger).to have_logged(/released 1 stale webhook request locks/)
    end

    it "leaves recently locked requests alone" do
      request = create(:webhook_request, :locked)
      task.call
      expect(request.reload).to be_locked
      expect(logger).not_to have_logged(/released/)
    end

    it "leaves unlocked requests alone" do
      request = create(:webhook_request)
      task.call
      expect(request.reload).not_to be_locked
    end
  end

  it "is scheduled by the worker" do
    expect(Worker::Process::TASKS).to include(described_class)
  end
end
