# frozen_string_literal: true

# == Schema Information
#
# Table name: user_invites
#
#  id            :integer          not null, primary key
#  uuid          :string(255)
#  email_address :string(255)
#  expires_at    :datetime
#  created_at    :datetime
#  updated_at    :datetime
#
# Indexes
#
#  index_user_invites_on_uuid  (uuid)
#
require "rails_helper"

describe UserInvite do
  subject(:invite) { described_class.new(email_address: "invitee@example.com") }

  describe "relationships" do
    it { is_expected.to have_many(:organization_users) }
    it { is_expected.to have_many(:organizations) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:email_address) }
    it { is_expected.to validate_uniqueness_of(:email_address).case_insensitive }
    it { is_expected.to allow_value("test@example.com").for(:email_address) }
    it { is_expected.to allow_value("test+tagged@example.co.uk").for(:email_address) }
    it { is_expected.to allow_value("TEST@EXAMPLE.COM").for(:email_address) }
    it { is_expected.to allow_value("test@localhost").for(:email_address) }
    it { is_expected.to allow_value("\"quoted name\"@example.com").for(:email_address) }
    it { is_expected.to allow_value("tëst@bücher.example").for(:email_address) }
    it { is_expected.to allow_value("test@[192.168.0.1]").for(:email_address) }
    it { is_expected.to_not allow_value("test").for(:email_address) }
    it { is_expected.to_not allow_value("test.example.com").for(:email_address) }
    it { is_expected.to_not allow_value("test at example.com").for(:email_address) }
    it { is_expected.to_not allow_value("test＠example.com").for(:email_address) }
    it { is_expected.to_not allow_value("").for(:email_address) }
    it { is_expected.to_not allow_value("   ").for(:email_address) }
    it { is_expected.to_not allow_value(nil).for(:email_address) }

    it "rejects an address without a local part or domain" do
      expect(invite).not_to allow_value("@").for(:email_address)
    end
  end

  describe "creation" do
    it "generates a UUID" do
      expect { invite.save }.to change { invite.uuid }.from(nil).to(/\A[a-f0-9-]{36}\z/)
    end

    it "defaults the expiry to seven days from now" do
      Timecop.freeze do
        invite.save
        expect(invite.expires_at).to be_within(1.second).of(7.days.from_now)
      end
    end
  end

  describe "#md5_for_gravatar" do
    it "hashes the downcased email address" do
      invite.email_address = "Invitee@Example.COM"
      expect(invite.md5_for_gravatar).to eq Digest::MD5.hexdigest("invitee@example.com")
    end
  end

  describe "#avatar_url" do
    it "returns a gravatar URL" do
      expect(invite.avatar_url).to eq "https://secure.gravatar.com/avatar/#{invite.md5_for_gravatar}?rating=PG&size=120&d=mm"
    end

    it "returns nil when there is no email address" do
      invite.email_address = nil
      expect(invite.avatar_url).to be_nil
    end
  end

  describe "#name" do
    it "returns the email address" do
      expect(invite.name).to eq "invitee@example.com"
    end
  end

  describe ".active" do
    it "returns only invites which have not expired" do
      active = described_class.create!(email_address: "active@example.com")
      described_class.create!(email_address: "expired@example.com", expires_at: 1.minute.ago)
      expect(described_class.active).to eq [active]
    end
  end
end
