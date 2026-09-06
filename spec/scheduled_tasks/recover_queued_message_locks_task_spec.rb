# frozen_string_literal: true

require "rails_helper"

RSpec.describe RecoverQueuedMessageLocksTask do
  let(:logger) { TestLogger.new }

  subject(:task) { described_class.new(logger: logger) }

  before do
    allow(Postal::Config.worker).to receive(:queued_message_lock_timeout).and_return(600)
  end

  describe "#call" do
    it "releases locks older than the lock timeout and schedules a retry" do
      message = create(:queued_message, :locked, locked_at: 11.minutes.ago, locked_by: "dead-worker", attempts: 2)
      task.call
      expect(message.reload).to have_attributes(locked_by: nil, locked_at: nil, attempts: 3)
      expect(message.retry_after).to be > Time.current
      expect(logger).to have_logged(/recovered 1 abandoned queued message locks/)
    end

    it "leaves locks that are still within the timeout alone" do
      message = create(:queued_message, :locked, locked_at: 9.minutes.ago, locked_by: "busy-worker")
      task.call
      expect(message.reload.locked_by).to eq "busy-worker"
      expect(logger).not_to have_logged(/recovered/)
    end

    it "leaves unlocked messages alone" do
      message = create(:queued_message)
      task.call
      expect(message.reload).not_to be_locked
    end
  end

  it "runs every minute" do
    expect(described_class.next_run_after).to be_within(5.seconds).of(1.minute.from_now)
  end

  it "is scheduled by the worker" do
    expect(Worker::Process::TASKS).to include(described_class)
  end
end
