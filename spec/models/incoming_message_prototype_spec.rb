# frozen_string_literal: true

require "rails_helper"

describe IncomingMessagePrototype do
  let(:server) { create(:server) }

  def prototype(attributes)
    described_class.new(server, "127.0.0.1", "TestSuite", attributes)
  end

  describe "#from_address" do
    def from_address(from)
      prototype(from: from).from_address
    end

    it "returns a bare address unchanged" do
      expect(from_address("john@example.com")).to eq "john@example.com"
    end

    it "strips surrounding whitespace" do
      expect(from_address("  john@example.com  ")).to eq "john@example.com"
    end

    it "extracts the address from angle brackets" do
      expect(from_address("<john@example.com>")).to eq "john@example.com"
    end

    it "strips a display name" do
      expect(from_address("John Doe <john@example.com>")).to eq "john@example.com"
    end

    it "strips a quoted display name" do
      expect(from_address("\"Doe, John\" <john@example.com>")).to eq "john@example.com"
    end

    it "strips a display name containing angle brackets" do
      expect(from_address("\"<not-me>\" <john@example.com>")).to eq "john@example.com"
    end

    it "strips whitespace inside the angle brackets" do
      expect(from_address("John < john@example.com >")).to eq "john@example.com"
    end

    it "strips text after the closing angle bracket" do
      expect(from_address("<john@example.com> (comment)")).to eq "john@example.com"
    end

    it "does not strip comments from a bare address" do
      expect(from_address("john@example.com (John)")).to eq "john@example.com (John)"
    end

    it "returns an empty string for an empty string" do
      expect(from_address("")).to eq ""
    end

    it "returns an empty string for empty angle brackets" do
      expect(from_address("John <>")).to eq ""
    end

    it "uses the last address when several are present" do
      expect(from_address("<a@example.com>, <b@example.com>")).to eq "b@example.com"
    end
  end

  describe "#route" do
    let(:domain) { create(:domain, owner: server) }
    let!(:route) { create(:route, server: server, domain: domain, name: "info") }

    def route_for(to)
      prototype(to: to).route
    end

    it "finds the route for a plain address" do
      expect(route_for("info@#{domain.name}")).to eq route
    end

    it "finds the route for a tagged address" do
      expect(route_for("info+newsletter@#{domain.name}")).to eq route
    end

    it "finds the route for an address with several plus signs" do
      expect(route_for("info+tag+more@#{domain.name}")).to eq route
    end

    it "finds the route for an address with an empty tag" do
      expect(route_for("info+@#{domain.name}")).to eq route
    end

    it "does not find a route when the tag contains an @" do
      expect(route_for("info+tag@x@#{domain.name}")).to be_nil
    end

    it "does not find a route when the tag is part of the name" do
      expect(route_for("infonewsletter@#{domain.name}")).to be_nil
    end

    it "does not find a route for a different local part" do
      expect(route_for("other@#{domain.name}")).to be_nil
    end

    it "does not find a route for a different domain" do
      expect(route_for("info@other.example.com")).to be_nil
    end

    it "does not find a route when the plus sign is in the domain" do
      expect(route_for("info@#{domain.name}+tag")).to be_nil
    end

    it "does not find a route for an address without a domain" do
      expect(route_for("info")).to be_nil
    end

    it "returns nil when there is no recipient" do
      expect(route_for(nil)).to be_nil
    end

    it "returns nil when the recipient is blank" do
      expect(route_for("")).to be_nil
    end
  end
end
