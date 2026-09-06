# frozen_string_literal: true

require "rails_helper"

module SMTPClient

  RSpec.describe Credentials do
    subject(:credentials) { described_class.new("relay-user", "relay-pass", auth_type: auth_type) }

    let(:auth_type) { nil }

    it "exposes the username and password" do
      expect(credentials).to have_attributes(username: "relay-user", password: "relay-pass")
    end

    it "defaults the auth type to login" do
      expect(credentials.auth_type).to eq :login
    end

    context "when an auth type is given" do
      let(:auth_type) { "CRAM_MD5" }

      it "normalises it to a lowercase symbol" do
        expect(credentials.auth_type).to eq :cram_md5
      end
    end

    it "never exposes the password when inspected or logged" do
      expect(credentials.inspect).to include("relay-user")
      expect(credentials.inspect).not_to include("relay-pass")
      expect(credentials.to_s).not_to include("relay-pass")
    end
  end

end
