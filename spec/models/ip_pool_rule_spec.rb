# frozen_string_literal: true

# == Schema Information
#
# Table name: ip_pool_rules
#
#  id         :integer          not null, primary key
#  from_text  :text(65535)
#  owner_type :string(255)
#  to_text    :text(65535)
#  uuid       :string(255)
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  ip_pool_id :integer
#  owner_id   :integer
#
require "rails_helper"

describe IPPoolRule do
  subject(:rule) { build(:ip_pool_rule) }

  describe "relationships" do
    it { is_expected.to belong_to(:ip_pool) }
  end

  describe "validations" do
    context "when neither from nor to conditions are given" do
      let(:rule) { build(:ip_pool_rule, from_text: nil, to_text: nil) }

      it "adds an error" do
        expect(rule).not_to be_valid
        expect(rule.errors[:base]).to include("At least one rule condition must be specified")
      end
    end

    context "when both from and to are empty strings" do
      let(:rule) { build(:ip_pool_rule, from_text: "", to_text: "") }

      it "adds an error" do
        expect(rule).not_to be_valid
        expect(rule.errors[:base]).to include("At least one rule condition must be specified")
      end
    end

    context "when only a from condition is given" do
      let(:rule) { build(:ip_pool_rule, from_text: "example.com", to_text: nil) }

      it "is valid" do
        expect(rule).to be_valid
      end
    end

    context "when only a to condition is given" do
      let(:rule) { build(:ip_pool_rule, from_text: nil, to_text: "example.com") }

      it "is valid" do
        expect(rule).to be_valid
      end
    end

    context "when the conditions consist only of whitespace" do
      let(:rule) { build(:ip_pool_rule, from_text: "  \n\t\n", to_text: " \r\n ") }

      it "adds an error" do
        expect(rule).not_to be_valid
        expect(rule.errors[:base]).to include("At least one rule condition must be specified")
      end
    end

    context "when a condition is mixed with blank lines" do
      let(:rule) { build(:ip_pool_rule, from_text: "\n\nexample.com\n\n", to_text: nil) }

      it "is valid" do
        expect(rule).to be_valid
      end
    end
  end

  describe "#from" do
    it "returns an empty array when from_text is nil" do
      expect(build(:ip_pool_rule, from_text: nil).from).to eq []
    end

    it "returns an empty array when from_text is empty" do
      expect(build(:ip_pool_rule, from_text: "").from).to eq []
    end

    it "splits on line feeds" do
      expect(build(:ip_pool_rule, from_text: "a.com\nb.com").from).to eq ["a.com", "b.com"]
    end

    it "splits on CRLF line endings" do
      expect(build(:ip_pool_rule, from_text: "a.com\r\nb.com\r\n").from).to eq ["a.com", "b.com"]
    end

    it "removes carriage returns wherever they appear" do
      expect(build(:ip_pool_rule, from_text: "a.com\r\r\nb.com\r").from).to eq ["a.com", "b.com"]
    end

    it "does not treat a bare carriage return as a line separator" do
      expect(build(:ip_pool_rule, from_text: "a.com\rb.com").from).to eq ["a.comb.com"]
    end

    it "strips surrounding whitespace from each line" do
      expect(build(:ip_pool_rule, from_text: "  a.com \t\n\tjohn@b.com  ").from).to eq ["a.com", "john@b.com"]
    end

    it "keeps interior blank lines as empty strings" do
      expect(build(:ip_pool_rule, from_text: "a.com\n\nb.com").from).to eq ["a.com", "", "b.com"]
    end

    it "drops trailing blank lines" do
      expect(build(:ip_pool_rule, from_text: "a.com\n\n\n").from).to eq ["a.com"]
    end

    it "does not split on spaces" do
      expect(build(:ip_pool_rule, from_text: "a.com b.com").from).to eq ["a.com b.com"]
    end
  end

  describe "#to" do
    it "returns an empty array when to_text is nil" do
      expect(build(:ip_pool_rule, to_text: nil).to).to eq []
    end

    it "splits on line feeds and strips whitespace" do
      expect(build(:ip_pool_rule, to_text: " a.com \r\n b.com ").to).to eq ["a.com", "b.com"]
    end

    it "keeps unicode conditions intact" do
      expect(build(:ip_pool_rule, to_text: "bücher.example\nxn--bcher-kva.example").to).to eq ["bücher.example", "xn--bcher-kva.example"]
    end
  end

  describe ".address_matches?" do
    context "when the condition is a domain" do
      it "matches an address at that domain" do
        expect(described_class.address_matches?("example.com", "john@example.com")).to be true
      end

      it "matches when the address includes a display name" do
        expect(described_class.address_matches?("example.com", "John Smith <john@example.com>")).to be true
      end

      it "matches when the address includes a comment" do
        expect(described_class.address_matches?("example.com", "john@example.com (John)")).to be true
      end

      it "matches when the address has surrounding whitespace" do
        expect(described_class.address_matches?("example.com", "  john@example.com\n")).to be true
      end

      it "matches a tagged address" do
        expect(described_class.address_matches?("example.com", "john+tag@example.com")).to be true
      end

      it "matches a bare domain with no local part" do
        expect(described_class.address_matches?("example.com", "example.com")).to be true
      end

      it "does not match a subdomain" do
        expect(described_class.address_matches?("example.com", "john@mail.example.com")).to be false
      end

      it "does not match a parent domain" do
        expect(described_class.address_matches?("mail.example.com", "john@example.com")).to be false
      end

      it "does not match a domain with a different suffix" do
        expect(described_class.address_matches?("example.com", "john@example.com.evil.net")).to be false
      end

      it "does not match a domain that merely contains the condition" do
        expect(described_class.address_matches?("example.com", "john@notexample.com")).to be false
      end

      it "does not match an empty address" do
        expect(described_class.address_matches?("example.com", "")).to be false
      end

      it "does not match an empty condition" do
        expect(described_class.address_matches?("", "john@example.com")).to be false
      end

      it "matches domains case-insensitively" do
        expect(described_class.address_matches?("Example.com", "john@example.com")).to be true
      end
    end

    context "when the condition is a full address" do
      it "matches the exact address" do
        expect(described_class.address_matches?("john@example.com", "john@example.com")).to be true
      end

      it "matches when the address includes a display name" do
        expect(described_class.address_matches?("john@example.com", "\"Smith, John\" <john@example.com>")).to be true
      end

      it "ignores a plus tag on the address" do
        expect(described_class.address_matches?("john@example.com", "john+newsletter@example.com")).to be true
      end

      it "ignores everything after the first plus" do
        expect(described_class.address_matches?("john@example.com", "john+a+b@example.com")).to be true
      end

      it "does not match a different local part" do
        expect(described_class.address_matches?("john@example.com", "jane@example.com")).to be false
      end

      it "does not match a different domain" do
        expect(described_class.address_matches?("john@example.com", "john@example.org")).to be false
      end

      it "does not match a local part that merely starts with the condition" do
        expect(described_class.address_matches?("john@example.com", "johnny@example.com")).to be false
      end

      it "does not match a local part that merely ends with the condition" do
        expect(described_class.address_matches?("john@example.com", "bigjohn@example.com")).to be false
      end

      it "does not match an address with no domain" do
        expect(described_class.address_matches?("john@example.com", "john")).to be false
      end

      it "does not match an empty address" do
        expect(described_class.address_matches?("john@example.com", "")).to be false
      end

      it "treats the last @ as the domain separator" do
        expect(described_class.address_matches?("a@b@example.com", "a@b@example.com")).to be true
      end

      it "matches a condition that itself contains a plus tag" do
        expect(described_class.address_matches?("john+tag@example.com", "john+tag@example.com")).to be true
      end
    end
  end

  describe "#apply_to_message?" do
    let(:rule) { build(:ip_pool_rule, from_text: from_text, to_text: to_text) }
    let(:from_text) { nil }
    let(:to_text) { nil }
    let(:message) { double("message", headers: headers, rcpt_to: rcpt_to) }
    let(:headers) { { "from" => ["John <john@example.com>"] } }
    let(:rcpt_to) { "jane@example.org" }

    context "with a matching from domain" do
      let(:from_text) { "other.com\nexample.com" }

      it "returns true" do
        expect(rule.apply_to_message?(message)).to be true
      end
    end

    context "with a matching to address" do
      let(:to_text) { "jane@example.org" }

      it "returns true" do
        expect(rule.apply_to_message?(message)).to be true
      end
    end

    context "with no matching conditions" do
      let(:from_text) { "example.org" }
      let(:to_text) { "example.com" }

      it "returns false" do
        expect(rule.apply_to_message?(message)).to be false
      end
    end

    context "when the message has no from header" do
      let(:headers) { {} }
      let(:from_text) { "example.com" }

      it "returns false" do
        expect(rule.apply_to_message?(message)).to be false
      end
    end

    context "when the message has no recipient" do
      let(:rcpt_to) { nil }
      let(:to_text) { "example.org" }

      it "returns false" do
        expect(rule.apply_to_message?(message)).to be false
      end
    end
  end
end
