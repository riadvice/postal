# frozen_string_literal: true

require "rails_helper"

RSpec.describe HasDNSChecks do
  subject(:domain) { build(:domain, name: "example.com") }

  let(:resolver) { instance_double(DNSResolver) }
  let(:spf_include) { Postal::Config.dns.spf_include }

  before do
    allow(domain).to receive(:resolver).and_return(resolver)
  end

  describe "#check_spf_record" do
    def check(records)
      allow(resolver).to receive(:txt).with("example.com").and_return(records)
      domain.check_spf_record
    end

    context "when there are no TXT records" do
      it "marks the record as missing" do
        check([])
        expect(domain.spf_status).to eq "Missing"
        expect(domain.spf_error).to eq "No SPF record exists for this domain"
      end
    end

    context "when there are TXT records but none are SPF records" do
      it "marks the record as missing" do
        check(["google-site-verification=abc", "postal-verification xyz"])
        expect(domain.spf_status).to eq "Missing"
      end
    end

    context "when the SPF record does not start at the beginning of the string" do
      it "marks the record as missing" do
        check([" v=spf1 include:#{spf_include} ~all", "x v=spf1 include:#{spf_include} ~all"])
        expect(domain.spf_status).to eq "Missing"
      end
    end

    context "when the SPF record includes the expected domain" do
      it "marks the record as OK and returns true" do
        expect(check(["v=spf1 a mx include:#{spf_include} ~all"])).to be true
        expect(domain.spf_status).to eq "OK"
        expect(domain.spf_error).to be_nil
      end
    end

    context "when the include is the only mechanism" do
      it "marks the record as OK" do
        check(["v=spf1 include:#{spf_include}"])
        expect(domain.spf_status).to eq "OK"
      end
    end

    context "when there is whitespace after include:" do
      it "marks the record as OK" do
        check(["v=spf1 include: \t#{spf_include} -all"])
        expect(domain.spf_status).to eq "OK"
      end
    end

    context "when only one of several SPF records is suitable" do
      it "marks the record as OK" do
        check(["v=spf1 include:_spf.google.com ~all", "v=spf1 include:#{spf_include} ~all"])
        expect(domain.spf_status).to eq "OK"
      end
    end

    context "when the SPF record includes a different domain" do
      it "marks the record as invalid and returns false" do
        expect(check(["v=spf1 include:_spf.google.com ~all"])).to be false
        expect(domain.spf_status).to eq "Invalid"
        expect(domain.spf_error).to eq "An SPF record exists but it doesn't include #{spf_include}"
      end
    end

    context "when the SPF record includes a domain that only differs by the dots" do
      it "marks the record as invalid" do
        check(["v=spf1 include:#{spf_include.tr('.', 'x')} ~all"])
        expect(domain.spf_status).to eq "Invalid"
      end
    end

    context "when the expected domain appears in a mechanism other than include" do
      it "marks the record as invalid" do
        check(["v=spf1 a:#{spf_include} redirect=#{spf_include}"])
        expect(domain.spf_status).to eq "Invalid"
      end
    end

    context "when the expected domain is a prefix of a longer include" do
      it "marks the record as invalid" do
        check(["v=spf1 include:#{spf_include}.evil.example ~all"])
        expect(domain.spf_status).to eq "Invalid"
      end
    end

    context "when the version tag is in upper case" do
      it "marks the record as OK" do
        check(["V=SPF1 include:#{spf_include} ~all"])
        expect(domain.spf_status).to eq "OK"
      end
    end

    context "when the version tag is not exactly spf1" do
      it "marks the record as missing" do
        check(["v=spf10 include:#{spf_include} ~all"])
        expect(domain.spf_status).to eq "Missing"
      end
    end
  end

  describe "#check_dkim_record" do
    before do
      domain.save
    end

    let(:record_name) { "#{domain.dkim_record_name}.example.com" }

    it "marks the record as missing when there are no TXT records" do
      allow(resolver).to receive(:txt).with(record_name).and_return([])
      domain.check_dkim_record
      expect(domain.dkim_status).to eq "Missing"
    end

    it "marks the record as OK when it matches" do
      allow(resolver).to receive(:txt).with(record_name).and_return([domain.dkim_record])
      domain.check_dkim_record
      expect(domain.dkim_status).to eq "OK"
    end

    it "tolerates a missing trailing semicolon and surrounding whitespace" do
      allow(resolver).to receive(:txt).with(record_name).and_return(["  #{domain.dkim_record.delete_suffix(';')}\n"])
      domain.check_dkim_record
      expect(domain.dkim_status).to eq "OK"
    end

    it "marks the record as invalid when it does not match" do
      allow(resolver).to receive(:txt).with(record_name).and_return(["v=DKIM1; t=s; h=sha256; p=abc;"])
      domain.check_dkim_record
      expect(domain.dkim_status).to eq "Invalid"
    end

    it "marks the record as invalid when there is more than one record" do
      allow(resolver).to receive(:txt).with(record_name).and_return([domain.dkim_record, domain.dkim_record])
      domain.check_dkim_record
      expect(domain.dkim_status).to eq "Invalid"
      expect(domain.dkim_error).to match(/There are 2 records/)
    end
  end

  describe "#check_mx_records" do
    let(:mx_records) { Postal::Config.dns.mx_records }

    it "marks the records as missing when there are none" do
      allow(resolver).to receive(:mx).with("example.com").and_return([])
      domain.check_mx_records
      expect(domain.mx_status).to eq "Missing"
    end

    it "marks the records as OK when all expected records exist" do
      allow(resolver).to receive(:mx).with("example.com").and_return(mx_records.map { |r| [10, r] })
      domain.check_mx_records
      expect(domain.mx_status).to eq "OK"
    end

    it "compares record names case-insensitively" do
      allow(resolver).to receive(:mx).with("example.com").and_return(mx_records.map { |r| [10, r.upcase] })
      domain.check_mx_records
      expect(domain.mx_status).to eq "OK"
    end

    it "marks the records as missing when none point to us" do
      allow(resolver).to receive(:mx).with("example.com").and_return([[10, "mx.google.com"]])
      domain.check_mx_records
      expect(domain.mx_status).to eq "Missing"
    end

    it "marks the records as invalid when only some point to us" do
      allow(resolver).to receive(:mx).with("example.com").and_return([[10, mx_records.first]])
      domain.check_mx_records
      expect(domain.mx_status).to eq "Invalid"
    end
  end

  describe "#check_return_path_record" do
    let(:return_path) { Postal::Config.dns.return_path_domain }

    it "marks the record as missing when there is no CNAME" do
      allow(resolver).to receive(:cname).with(domain.return_path_domain).and_return([])
      domain.check_return_path_record
      expect(domain.return_path_status).to eq "Missing"
    end

    it "marks the record as OK when the CNAME matches" do
      allow(resolver).to receive(:cname).with(domain.return_path_domain).and_return([return_path])
      domain.check_return_path_record
      expect(domain.return_path_status).to eq "OK"
    end

    it "marks the record as invalid when the CNAME points elsewhere" do
      allow(resolver).to receive(:cname).with(domain.return_path_domain).and_return(["rp.example.org"])
      domain.check_return_path_record
      expect(domain.return_path_status).to eq "Invalid"
    end
  end
end
