# frozen_string_literal: true

require "rails_helper"

RSpec.describe Postal::Helpers do
  describe ".strip_name_from_address" do
    def strip(address)
      described_class.strip_name_from_address(address)
    end

    it "returns nil for nil" do
      expect(strip(nil)).to be_nil
    end

    it "returns a bare address unchanged" do
      expect(strip("john@example.com")).to eq "john@example.com"
    end

    it "strips surrounding whitespace from a bare address" do
      expect(strip("  john@example.com \t\n")).to eq "john@example.com"
    end

    it "returns an empty string for an empty string" do
      expect(strip("")).to eq ""
    end

    it "extracts the address from angle brackets" do
      expect(strip("<john@example.com>")).to eq "john@example.com"
    end

    it "strips a display name" do
      expect(strip("John Doe <john@example.com>")).to eq "john@example.com"
    end

    it "strips a quoted display name" do
      expect(strip("\"John Doe\" <john@example.com>")).to eq "john@example.com"
    end

    it "strips a quoted display name containing a comma" do
      expect(strip("\"Doe, John\" <john@example.com>")).to eq "john@example.com"
    end

    it "strips a display name containing an @" do
      expect(strip("john@other.com <john@example.com>")).to eq "john@example.com"
    end

    it "strips a display name containing angle brackets" do
      expect(strip("\"<not-me>\" <john@example.com>")).to eq "john@example.com"
    end

    it "strips text after the closing angle bracket" do
      expect(strip("<john@example.com> extra text")).to eq "john@example.com"
    end

    it "strips whitespace inside the angle brackets" do
      expect(strip("John <  john@example.com  >")).to eq "john@example.com"
    end

    it "strips a trailing comment" do
      expect(strip("john@example.com (John Doe)")).to eq "john@example.com"
    end

    it "strips a leading comment" do
      expect(strip("(John Doe) john@example.com")).to eq "john@example.com"
    end

    it "strips several comments" do
      expect(strip("(a) john@example.com (b)")).to eq "john@example.com"
    end

    it "uses the last opening angle bracket even when it is inside a trailing comment" do
      expect(strip("<john@example.com> (John <Doe>)")).to eq "Doe"
    end

    it "strips a comment inside the display name" do
      expect(strip("John (Johnny) Doe <john@example.com>")).to eq "john@example.com"
    end

    it "does not strip empty parentheses" do
      expect(strip("john@example.com ()")).to eq "john@example.com ()"
    end

    it "keeps the case of the address" do
      expect(strip("John <John.Doe@Example.COM>")).to eq "John.Doe@Example.COM"
    end

    it "keeps non-ASCII characters in the address" do
      expect(strip("Jöhn <jöhn@exämple.com>")).to eq "jöhn@exämple.com"
    end

    it "returns an empty string for empty angle brackets" do
      expect(strip("John <>")).to eq ""
    end

    it "returns everything after the last opening angle bracket when it is not closed" do
      expect(strip("John <john@example.com")).to eq "john@example.com"
    end

    it "returns everything before the first closing angle bracket when it is not opened" do
      expect(strip("john@example.com> John")).to eq "john@example.com"
    end

    it "uses the last address when several are present" do
      expect(strip("<a@example.com>, <b@example.com>")).to eq "b@example.com"
    end
  end
end
