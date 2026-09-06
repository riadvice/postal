# frozen_string_literal: true

require "rails_helper"

module SMTPServer

  describe Server do
    describe ".tls_certificates" do
      let(:path) { "/config/smtp.cert" }
      let(:certificates) { [generate_certificate("one.example.com")] }
      let(:data) { certificates.join }

      def generate_certificate(common_name)
        key = OpenSSL::PKey::EC.generate("prime256v1")
        cert = OpenSSL::X509::Certificate.new
        cert.version = 2
        cert.serial = 1
        cert.subject = OpenSSL::X509::Name.parse("/CN=#{common_name}")
        cert.issuer = cert.subject
        cert.public_key = key
        cert.not_before = Time.now
        cert.not_after = Time.now + 3600
        cert.sign(key, OpenSSL::Digest.new("SHA256"))
        cert.to_pem
      end

      def common_names
        described_class.tls_certificates.map { |c| c.subject.to_a.find { |name, _, _| name == "CN" }[1] }
      end

      before do
        described_class.instance_variable_set(:@tls_certificates, nil)
        allow(Postal::Config.smtp_server).to receive(:tls_certificate_path).and_return(path)
        allow(File).to receive(:read).and_call_original
        allow(File).to receive(:read).with(path).and_return(data)
      end

      after do
        described_class.instance_variable_set(:@tls_certificates, nil)
      end

      it "returns a single certificate" do
        expect(common_names).to eq ["one.example.com"]
      end

      it "returns a frozen array" do
        expect(described_class.tls_certificates).to be_frozen
      end

      it "memoizes the result" do
        first = described_class.tls_certificates
        expect(described_class.tls_certificates).to equal first
        expect(File).to have_received(:read).with(path).once
      end

      context "when the file contains a chain" do
        let(:certificates) { [generate_certificate("one.example.com"), generate_certificate("two.example.com"), generate_certificate("three.example.com")] }

        it "returns each certificate in order" do
          expect(common_names).to eq ["one.example.com", "two.example.com", "three.example.com"]
        end
      end

      context "when the certificates are not separated by a newline" do
        let(:data) { certificates.map(&:strip).join }
        let(:certificates) { [generate_certificate("one.example.com"), generate_certificate("two.example.com")] }

        it "returns each certificate" do
          expect(common_names).to eq ["one.example.com", "two.example.com"]
        end
      end

      context "when the file uses CRLF line endings" do
        let(:data) { certificates.join.gsub("\n", "\r\n") }

        it "returns the certificate" do
          expect(common_names).to eq ["one.example.com"]
        end
      end

      context "when the file contains text around the certificates" do
        let(:certificates) { [generate_certificate("one.example.com"), generate_certificate("two.example.com")] }
        let(:data) do
          "Bag Attributes\n    friendlyName: one\nsubject=CN = one.example.com\n" +
            certificates[0] +
            "Bag Attributes\n    friendlyName: two\n" +
            certificates[1] +
            "trailing text\n"
        end

        it "ignores the surrounding text" do
          expect(common_names).to eq ["one.example.com", "two.example.com"]
        end
      end

      context "when the file contains a private key" do
        let(:data) { certificates.join + OpenSSL::PKey::EC.generate("prime256v1").to_pem }

        it "ignores the key" do
          expect(common_names).to eq ["one.example.com"]
        end
      end

      context "when the file is empty" do
        let(:data) { "" }

        it "returns an empty array" do
          expect(described_class.tls_certificates).to eq []
        end
      end

      context "when the file does not contain a certificate" do
        let(:data) { "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n" }

        it "returns an empty array" do
          expect(described_class.tls_certificates).to eq []
        end
      end

      context "when a certificate is missing its end marker" do
        let(:data) { certificates.join.sub("-----END CERTIFICATE-----", "") }

        it "returns an empty array" do
          expect(described_class.tls_certificates).to eq []
        end
      end

      context "when the markers are in the wrong case" do
        let(:data) { certificates.join.gsub("CERTIFICATE", "certificate") }

        it "returns an empty array" do
          expect(described_class.tls_certificates).to eq []
        end
      end

      context "when a certificate is truncated before the next one" do
        let(:certificates) { [generate_certificate("one.example.com"), generate_certificate("two.example.com")] }
        let(:data) { certificates[0].sub("-----END CERTIFICATE-----", "") + certificates[1] }

        it "raises an error for the merged block" do
          expect { described_class.tls_certificates }.to raise_error(OpenSSL::X509::CertificateError)
        end
      end

      context "when the certificate body is not valid" do
        let(:data) { "-----BEGIN CERTIFICATE-----\nnot base64\n-----END CERTIFICATE-----\n" }

        it "raises an error" do
          expect { described_class.tls_certificates }.to raise_error(OpenSSL::X509::CertificateError)
        end
      end
    end
  end

end
