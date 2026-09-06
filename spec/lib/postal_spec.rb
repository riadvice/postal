# frozen_string_literal: true

require "rails_helper"

RSpec.describe Postal do
  describe "#signer" do
    it "returns a signer with the installation's signing key" do
      expect(Postal.signer).to be_a(Postal::Signer)
      expect(Postal.signer.private_key.to_pem).to eq OpenSSL::PKey::RSA.new(File.read(Postal::Config.postal.signing_key_path)).to_pem
    end
  end

  describe "#rp_dkim_dns_record" do
    subject(:record) { Postal.rp_dkim_dns_record }

    it "returns a DKIM record" do
      expect(record).to match(/\Av=DKIM1; t=s; h=sha256; p=[A-Za-z0-9+\/=]+;\z/)
    end

    it "strips the PEM armour and newlines from the public key" do
      expect(record).not_to include("\n")
      expect(record).not_to include("BEGIN")
      expect(record).not_to include("END")
      expect(record).not_to include("-")
    end

    it "includes the DER-encoded public key" do
      public_key = record[/p=([^;]+);/, 1]
      expect(public_key).to eq Base64.strict_encode64(Postal.signer.private_key.public_key.to_der)
    end
  end

  describe "#change_database_connection_pool_size" do
    it "changes the connection pool size" do
      expect { Postal.change_database_connection_pool_size(8) }.to change { ActiveRecord::Base.connection_pool.size }.from(5).to(8)
    end
  end
end
