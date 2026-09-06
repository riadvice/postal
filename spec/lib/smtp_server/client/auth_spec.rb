# frozen_string_literal: true

require "rails_helper"

module SMTPServer

  describe Client do
    let(:ip_address) { "1.2.3.4" }
    subject(:client) { described_class.new(ip_address) }

    before do
      client.handle("HELO test.example.com")
    end

    describe "AUTH PLAIN" do
      context "when no credentials are provided on the initial data" do
        it "returns a 334" do
          expect(client.handle("AUTH PLAIN")).to eq("334")
        end

        it "accepts the username and password from the next input" do
          client.handle("AUTH PLAIN")
          credential = create(:credential, type: "SMTP")
          expect(client.handle(credential.to_smtp_plain)).to match(/235 Granted for/)
        end
      end

      context "when valid credentials are provided on one line" do
        it "authenticates and returns a response" do
          credential = create(:credential, type: "SMTP")
          expect(client.handle("AUTH PLAIN #{credential.to_smtp_plain}")).to match(/235 Granted for/)
          expect(client.credential).to eq credential
        end
      end

      context "when invalid credentials are provided" do
        it "returns an error and resets the state" do
          base64 = Base64.encode64("user\0pass")
          expect(client.handle("AUTH PLAIN #{base64}")).to eq("535 Invalid credential")
          expect(client.state).to eq :welcomed
        end
      end

      context "when username or password is missing" do
        it "returns an error and resets the state" do
          base64 = Base64.encode64("pass")
          expect(client.handle("AUTH PLAIN #{base64}")).to eq("535 Authenticated failed - protocol error")
          expect(client.state).to eq :welcomed
        end
      end

      context "when parsing the command line" do
        let(:credential) { create(:credential, type: "SMTP") }

        it "accepts a lowercase command" do
          expect(client.handle("auth plain #{credential.to_smtp_plain}")).to match(/235 Granted for/)
        end

        it "accepts a mixed case command" do
          expect(client.handle("Auth Plain #{credential.to_smtp_plain}")).to match(/235 Granted for/)
        end

        it "accepts more than one space before the credentials" do
          expect(client.handle("AUTH PLAIN    #{credential.to_smtp_plain}")).to match(/235 Granted for/)
        end

        it "accepts trailing whitespace after the command" do
          expect(client.handle("AUTH PLAIN   ")).to eq "334"
          expect(client.handle(credential.to_smtp_plain)).to match(/235 Granted for/)
        end

        it "accepts credentials with no space after the command" do
          expect(client.handle("AUTH PLAIN#{credential.to_smtp_plain}")).to match(/235 Granted for/)
        end

        it "accepts base64 with a trailing line feed" do
          expect(client.handle("AUTH PLAIN #{Base64.encode64("\0XX\0#{credential.key}")}")).to match(/235 Granted for/)
        end

        it "accepts base64 split over multiple lines" do
          expect(client.handle("AUTH PLAIN #{Base64.encode64("\0XX#{'X' * 100}\0#{credential.key}")}")).to match(/235 Granted for/)
        end

        it "accepts base64 without padding" do
          base64 = credential.to_smtp_plain.delete("=")
          expect(client.handle("AUTH PLAIN #{base64}")).to match(/235 Granted for/)
        end

        it "accepts an authorization identity as the first part" do
          base64 = Base64.strict_encode64("authzid\0user\0#{credential.key}")
          expect(client.handle("AUTH PLAIN #{base64}")).to match(/235 Granted for/)
        end

        it "uses the last two null separated parts" do
          base64 = Base64.strict_encode64("a\0b\0c\0#{credential.key}")
          expect(client.handle("AUTH PLAIN #{base64}")).to match(/235 Granted for/)
        end

        it "accepts a username and password with no leading null" do
          base64 = Base64.strict_encode64("user\0#{credential.key}")
          expect(client.handle("AUTH PLAIN #{base64}")).to match(/235 Granted for/)
        end

        it "returns an error when the base64 is not decodable" do
          expect(client.handle("AUTH PLAIN !!!")).to eq "535 Authenticated failed - protocol error"
          expect(client.state).to eq :welcomed
        end

        it "returns an error when the decoded value has no null separator" do
          expect(client.handle("AUTH PLAIN #{Base64.strict_encode64('nonulls')}")).to eq "535 Authenticated failed - protocol error"
        end

        it "returns an error when an empty line follows the command" do
          expect(client.handle("AUTH PLAIN")).to eq "334"
          expect(client.handle("")).to eq "535 Authenticated failed - protocol error"
        end

        it "treats the username as the password when the password is empty" do
          base64 = Base64.strict_encode64("\0user\0")
          expect(client.handle("AUTH PLAIN #{base64}")).to eq "535 Invalid credential"
        end

        it "returns an error when only null bytes are sent" do
          base64 = Base64.strict_encode64("\0\0")
          expect(client.handle("AUTH PLAIN #{base64}")).to eq "535 Authenticated failed - protocol error"
        end

        it "returns an error for a very long credential" do
          base64 = Base64.strict_encode64("\0user\0#{'a' * 100_000}")
          expect(client.handle("AUTH PLAIN #{base64}")).to eq "535 Invalid credential"
        end

        it "does not authenticate a credential of another type" do
          api_credential = create(:credential, type: "API")
          expect(client.handle("AUTH PLAIN #{api_credential.to_smtp_plain}")).to eq "535 Invalid credential"
        end

        it "does not authenticate a partial key" do
          base64 = Base64.strict_encode64("\0XX\0#{credential.key[0..-2]}")
          expect(client.handle("AUTH PLAIN #{base64}")).to eq "535 Invalid credential"
        end
      end
    end

    describe "AUTH LOGIN" do
      context "when no username is provided on the first line" do
        it "requests the username" do
          expect(client.handle("AUTH LOGIN")).to eq("334 VXNlcm5hbWU6")
        end

        it "requests a password after a username" do
          client.handle("AUTH LOGIN")
          expect(client.handle("xx")).to eq("334 UGFzc3dvcmQ6")
        end

        it "authenticates and returns a response if the password is correct" do
          client.handle("AUTH LOGIN")
          client.handle("xx")
          credential = create(:credential, type: "SMTP")
          password = Base64.encode64(credential.key)
          expect(client.handle(password)).to match(/235 Granted for/)
        end

        it "returns an error when an invalid credential is provided" do
          client.handle("AUTH LOGIN")
          client.handle("xx")
          password = Base64.encode64("xx")
          expect(client.handle(password)).to eq("535 Invalid credential")
        end
      end

      context "when a username is provided on the first line" do
        it "requests a password" do
          username = Base64.encode64("xx")
          expect(client.handle("AUTH LOGIN #{username}")).to eq("334 UGFzc3dvcmQ6")
        end

        it "authenticates and returns a response" do
          credential = create(:credential, type: "SMTP")
          username = Base64.encode64("xx")
          password = Base64.encode64(credential.key)
          expect(client.handle("AUTH LOGIN #{username}")).to eq("334 UGFzc3dvcmQ6")
          expect(client.handle(password)).to match(/235 Granted for/)
          expect(client.credential).to eq credential
        end

        it "returns an error and resets the state" do
          username = Base64.encode64("xx")
          password = Base64.encode64("xx")
          expect(client.handle("AUTH LOGIN #{username}")).to eq("334 UGFzc3dvcmQ6")
          expect(client.handle(password)).to eq("535 Invalid credential")
          expect(client.state).to eq :welcomed
        end
      end

      context "when parsing the command line" do
        let(:credential) { create(:credential, type: "SMTP") }

        it "accepts a lowercase command" do
          expect(client.handle("auth login")).to eq "334 VXNlcm5hbWU6"
        end

        it "accepts a lowercase command with a username" do
          expect(client.handle("auth login #{Base64.strict_encode64('xx')}")).to eq "334 UGFzc3dvcmQ6"
        end

        it "accepts trailing whitespace after the command" do
          expect(client.handle("AUTH LOGIN   ")).to eq "334 VXNlcm5hbWU6"
        end

        it "accepts more than one space before the username" do
          expect(client.handle("AUTH LOGIN    #{Base64.strict_encode64('xx')}")).to eq "334 UGFzc3dvcmQ6"
        end

        it "accepts a username with no space after the command" do
          expect(client.handle("AUTH LOGIN#{Base64.strict_encode64('xx')}")).to eq "334 UGFzc3dvcmQ6"
        end

        it "ignores the username entirely" do
          client.handle("AUTH LOGIN !!! not base64 at all")
          expect(client.handle(Base64.strict_encode64(credential.key))).to match(/235 Granted for/)
        end

        it "accepts an empty username line" do
          client.handle("AUTH LOGIN")
          expect(client.handle("")).to eq "334 UGFzc3dvcmQ6"
          expect(client.handle(Base64.strict_encode64(credential.key))).to match(/235 Granted for/)
        end

        it "accepts a password without base64 padding" do
          client.handle("AUTH LOGIN")
          client.handle("xx")
          expect(client.handle(Base64.strict_encode64(credential.key).delete("="))).to match(/235 Granted for/)
        end

        it "returns an error when the password is not decodable" do
          client.handle("AUTH LOGIN")
          client.handle("xx")
          expect(client.handle("!!!")).to eq "535 Invalid credential"
          expect(client.state).to eq :welcomed
        end

        it "returns an error when the password line is empty" do
          client.handle("AUTH LOGIN")
          client.handle("xx")
          expect(client.handle("")).to eq "535 Invalid credential"
        end

        it "treats a command sent as the password as the password" do
          client.handle("AUTH LOGIN")
          client.handle("xx")
          expect(client.handle("QUIT")).to eq "535 Invalid credential"
          expect(client.finished?).to be false
        end
      end
    end

    describe "AUTH CRAM-MD5" do
      context "when valid credentials are provided" do
        it "authenticates and returns a response" do
          credential = create(:credential, type: "SMTP")
          result = client.handle("AUTH CRAM-MD5")
          expect(result).to match(/\A334 [A-Za-z0-9=]+\z/)
          challenge = Base64.decode64(result.split[1])
          password = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new("md5"), credential.key, challenge)
          base64 = Base64.encode64("#{credential.server.organization.permalink}/#{credential.server.permalink} #{password}")
          expect(client.handle(base64)).to match(/235 Granted for/)
          expect(client.credential).to eq credential
        end
      end

      context "when no org/server matches the provided username" do
        it "returns an error" do
          client.handle("AUTH CRAM-MD5")
          base64 = Base64.encode64("org/server password")
          expect(client.handle(base64)).to eq "535 Denied"
        end
      end

      context "when invalid credentials are provided" do
        it "returns an error and resets the state" do
          server = create(:server)
          base64 = Base64.encode64("#{server.organization.permalink}/#{server.permalink} invalid-password")
          client.handle("AUTH CRAM-MD5")
          expect(client.handle(base64)).to eq("535 Denied")
        end
      end

      context "when parsing the challenge and response" do
        let(:credential) { create(:credential, type: "SMTP") }
        let(:server) { credential.server }

        def respond(username)
          result = client.handle("AUTH CRAM-MD5")
          challenge = Base64.decode64(result.split[1])
          digest = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new("md5"), credential.key, challenge)
          client.handle(Base64.strict_encode64("#{username} #{digest}"))
        end

        it "returns a challenge as a single line of base64" do
          result = client.handle("AUTH CRAM-MD5")
          expect(result).not_to include "\n"
          expect(result).not_to include "\r"
          expect(result).to match(/\A334 [A-Za-z0-9+\/=]+\z/)
        end

        it "returns a challenge in message id form" do
          result = client.handle("AUTH CRAM-MD5")
          challenge = Base64.decode64(result.split[1])
          expect(challenge).to match(/\A<[a-f0-9]{20}@#{Regexp.escape(Postal::Config.postal.smtp_hostname)}>\z/)
        end

        it "returns a different challenge for each request" do
          first = client.handle("AUTH CRAM-MD5")
          client.handle(Base64.strict_encode64("org/server password"))
          second = client.handle("AUTH CRAM-MD5")
          expect(first).not_to eq second
        end

        it "accepts a lowercase command" do
          expect(client.handle("auth cram-md5")).to match(/\A334 /)
        end

        it "accepts the username with an underscore separator" do
          expect(respond("#{server.organization.permalink}_#{server.permalink}")).to match(/235 Granted for/)
          expect(client.credential).to eq credential
        end

        it "accepts the username with a slash separator" do
          expect(respond("#{server.organization.permalink}/#{server.permalink}")).to match(/235 Granted for/)
        end

        it "returns an error when the username has no separator" do
          expect(respond(server.organization.permalink)).to eq "535 Denied"
        end

        it "returns an error when the username has a trailing separator" do
          expect(respond("#{server.organization.permalink}/#{server.permalink}/")).to eq "535 Denied"
        end

        it "returns an error when the username is in the wrong order" do
          expect(respond("#{server.permalink}/#{server.organization.permalink}")).to eq "535 Denied"
        end

        it "returns an error when the username has an unsupported separator" do
          expect(respond("#{server.organization.permalink}:#{server.permalink}")).to eq "535 Denied"
        end

        it "returns an error when the digest is uppercase" do
          result = client.handle("AUTH CRAM-MD5")
          challenge = Base64.decode64(result.split[1])
          digest = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new("md5"), credential.key, challenge)
          expect(client.handle(Base64.strict_encode64("#{server.organization.permalink}/#{server.permalink} #{digest.upcase}"))).to eq "535 Denied"
        end

        it "returns an error when the response has no space" do
          client.handle("AUTH CRAM-MD5")
          expect(client.handle(Base64.strict_encode64("#{server.organization.permalink}/#{server.permalink}"))).to eq "535 Denied"
        end

        it "returns an error when the response is not decodable" do
          client.handle("AUTH CRAM-MD5")
          expect(client.handle("!!!")).to eq "535 Denied"
        end

        it "returns an error when the response line is empty" do
          client.handle("AUTH CRAM-MD5")
          expect(client.handle("")).to eq "535 Denied"
        end
      end
    end
  end

end
