# frozen_string_literal: true

require "rails_helper"

describe QueryString do
  it "works with a single item" do
    qs = described_class.new("to: test@example.com")
    expect(qs.hash["to"]).to eq "test@example.com"
  end

  it "works with a multiple items" do
    qs = described_class.new("to: test@example.com from: another@example.com")
    expect(qs.hash["to"]).to eq "test@example.com"
    expect(qs.hash["from"]).to eq "another@example.com"
  end

  it "does not require a space after the field name" do
    qs = described_class.new("to:test@example.com from:another@example.com")
    expect(qs.hash["to"]).to eq "test@example.com"
    expect(qs.hash["from"]).to eq "another@example.com"
  end

  it "returns nil when it receives blank" do
    qs = described_class.new("to:[blank]")
    expect(qs.hash["to"]).to eq nil
  end

  it "returns nil for an empty value" do
    qs = described_class.new("from: another@example.com to: ")
    expect(qs.hash["to"]).to eq nil
    expect(qs.hash["from"]).to eq "another@example.com"
  end

  it "returns nil for an empty quoted value" do
    qs = described_class.new('subject: ""')
    expect(qs.hash["subject"]).to eq nil
  end

  it "handles dates with spaces" do
    qs = described_class.new("date: 2017-02-12 15:20")
    expect(qs.hash["date"]).to eq("2017-02-12 15:20")
  end

  it "returns an array for multiple items" do
    qs = described_class.new("to: test@example.com to: another@example.com")
    expect(qs.hash["to"]).to be_a(Array)
    expect(qs.hash["to"][0]).to eq "test@example.com"
    expect(qs.hash["to"][1]).to eq "another@example.com"
  end

  it "works with a z in the string" do
    qs = described_class.new("to: testaz@example.com")
    expect(qs.hash["to"]).to eq "testaz@example.com"
  end

  describe "#key?" do
    it "is true for a key with a blank value" do
      qs = described_class.new("tag: [blank]")
      expect(qs.key?(:tag)).to be true
      expect(qs[:tag]).to be_nil
    end

    it "is false for a key which was not given" do
      expect(described_class.new("to: x").key?(:tag)).to be false
    end
  end

  describe "STATUSES" do
    it "lists every status a message can have" do
      expect(described_class::STATUSES).to match_array %w[Pending Sent Held SoftFail HardFail Bounced Error Processed]
    end
  end

  describe "#unrecognized_keys" do
    it "is empty when every key is recognized" do
      qs = described_class.new("to: test@example.com status: held")
      expect(qs.unrecognized_keys).to eq []
    end

    it "lists keys that aren't recognized" do
      qs = described_class.new("to: test@example.com fromm: test@example.com")
      expect(qs.unrecognized_keys).to eq ["fromm"]
    end

    it "lists each unrecognized key only once" do
      qs = described_class.new("bogus: 1 bogus: 2")
      expect(qs.unrecognized_keys).to eq ["bogus"]
    end
  end
end
