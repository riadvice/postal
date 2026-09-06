# frozen_string_literal: true

require "rails_helper"

describe DKIMHeader do
  examples = Rails.root.join("spec/examples/dkim_signing/*.msg")
  Dir[examples].each do |path|
    contents = File.read(path)
    frontmatter, email = contents.split(/^---\n/m, 2)
    frontmatter = YAML.safe_load(frontmatter)
    email.strip
    it "works with #{path.split('/').last}" do
      mocked_time = Time.at(frontmatter["time"].to_i)
      allow(Time).to receive(:now).and_return(mocked_time)

      domain = instance_double("Domain")
      allow(domain).to receive(:dkim_status).and_return("OK")
      allow(domain).to receive(:name).and_return(frontmatter["domain"])
      allow(domain).to receive(:dkim_key).and_return(OpenSSL::PKey::RSA.new(frontmatter["private_key"]))
      allow(domain).to receive(:dkim_identifier).and_return(frontmatter["dkim_identifier"])

      expectation = "DKIM-Signature: v=1; a=rsa-sha256; c=relaxed/relaxed;\r\n" \
                    "\td=#{frontmatter['domain']};\r\n" \
                    "\ts=#{frontmatter['dkim_identifier']}; t=#{mocked_time.to_i};\r\n" \
                    "\tbh=#{frontmatter['bh']};\r\n" \
                    "\th=#{frontmatter['headers']};\r\n" \
                    "\tb=#{frontmatter['b'].scan(/.{1,72}/).join("\r\n\t")}"

      header = described_class.new(domain, email)

      expect(header.dkim_header).to eq expectation
    end
  end

  describe "canonicalisation" do
    let(:private_key) { OpenSSL::PKey::RSA.new(1024) }
    let(:domain) do
      instance_double("Domain", dkim_status: "OK", name: "example.com", dkim_key: private_key, dkim_identifier: "postal")
    end

    def build(message)
      described_class.new(domain, message)
    end

    def canonical_body(message)
      build(message).send(:normalized_body)
    end

    def canonical_headers(message)
      build(message).send(:normalized_headers)
    end

    def signed_header_names(message)
      build(message).send(:header_names)
    end

    def dkim_tags(header)
      header.sub(/\ADKIM-Signature: /, "").gsub("\r\n\t", "").split(";").to_h do |pair|
        key, value = pair.strip.split("=", 2)
        [key, value]
      end
    end

    def body_hash_of(body)
      Base64.strict_encode64(Digest::SHA256.digest(body))
    end

    describe "line ending normalisation" do
      it "produces the same canonical body for LF and CRLF input" do
        lf = "From: a@example.com\nSubject: Hi\n\nline one\nline two\n"
        crlf = "From: a@example.com\r\nSubject: Hi\r\n\r\nline one\r\nline two\r\n"
        expect(canonical_body(lf)).to eq "line one\r\nline two\r\n"
        expect(canonical_body(lf)).to eq canonical_body(crlf)
      end

      it "produces the same canonical headers for LF and CRLF input" do
        lf = "From: a@example.com\nSubject: Hi\n there\n\nbody"
        crlf = "From: a@example.com\r\nSubject: Hi\r\n there\r\n\r\nbody"
        expect(canonical_headers(lf)).to eq ["from:a@example.com", "subject:Hi there"]
        expect(canonical_headers(lf)).to eq canonical_headers(crlf)
      end

      it "handles mixed line endings within a single message" do
        mixed = "From: a@example.com\r\nSubject: Hi\n\r\nline one\nline two\r\n"
        expect(canonical_headers(mixed)).to eq ["from:a@example.com", "subject:Hi"]
        expect(canonical_body(mixed)).to eq "line one\r\nline two\r\n"
      end

      it "produces an identical signature for LF and CRLF input" do
        lf = "From: a@example.com\nSubject: Hi\n\nbody\n"
        crlf = "From: a@example.com\r\nSubject: Hi\r\n\r\nbody\r\n"
        Timecop.freeze do
          expect(build(lf).dkim_header).to eq build(crlf).dkim_header
        end
      end

      it "splits headers from the body at the first blank line only" do
        message = "From: a@example.com\r\n\r\npara one\r\n\r\npara two\r\n"
        expect(canonical_headers(message)).to eq ["from:a@example.com"]
        expect(canonical_body(message)).to eq "para one\r\n\r\npara two\r\n"
      end

      it "does not treat a whitespace-only line as the header/body separator" do
        message = "From: a@example.com\r\n \r\nSubject: Hi\r\n\r\nbody\r\n"
        expect(canonical_headers(message)).to eq ["from:a@example.com", "subject:Hi"]
        expect(canonical_body(message)).to eq "body\r\n"
      end
    end

    describe "body canonicalisation" do
      it "reduces runs of spaces and tabs within a line to a single space" do
        expect(canonical_body("\r\n\r\nhello    \t  world\r\n")).to eq "hello world\r\n"
      end

      it "reduces a single tab to a single space" do
        expect(canonical_body("\r\n\r\nhello\tworld\r\n")).to eq "hello world\r\n"
      end

      it "reduces leading whitespace on a line to a single space" do
        expect(canonical_body("\r\n\r\n   \t indented\r\n")).to eq " indented\r\n"
      end

      it "removes trailing spaces at the end of each line" do
        expect(canonical_body("\r\n\r\nline one   \r\nline two \r\n")).to eq "line one\r\nline two\r\n"
      end

      it "removes trailing tabs at the end of each line" do
        expect(canonical_body("\r\n\r\nline one\t\t\r\nline two\t \t\r\n")).to eq "line one\r\nline two\r\n"
      end

      it "removes trailing whitespace on a final line with no line ending" do
        expect(canonical_body("\r\n\r\nline one\r\nline two   ")).to eq "line one\r\nline two\r\n"
      end

      it "removes a single trailing empty line" do
        expect(canonical_body("\r\n\r\nbody\r\n\r\n")).to eq "body\r\n"
      end

      it "removes many trailing empty lines" do
        expect(canonical_body("\r\n\r\nbody\r\n\r\n\r\n\r\n\r\n")).to eq "body\r\n"
      end

      it "removes trailing lines that only contain whitespace" do
        expect(canonical_body("\r\n\r\nbody\r\n  \r\n\t\r\n \t \r\n")).to eq "body\r\n"
      end

      it "removes trailing empty lines when input uses LF line endings" do
        expect(canonical_body("\n\nbody\n\n\n\n")).to eq "body\r\n"
      end

      it "keeps empty lines in the middle of the body" do
        expect(canonical_body("\r\n\r\none\r\n\r\n\r\ntwo\r\n")).to eq "one\r\n\r\n\r\ntwo\r\n"
      end

      it "turns whitespace-only lines in the middle of the body into empty lines" do
        expect(canonical_body("\r\n\r\none\r\n \t \r\ntwo\r\n")).to eq "one\r\n\r\ntwo\r\n"
      end

      it "adds a CRLF when the body does not end with one" do
        expect(canonical_body("\r\n\r\nno newline")).to eq "no newline\r\n"
      end

      it "does not add a second CRLF when the body already ends with one" do
        expect(canonical_body("\r\n\r\nbody\r\n")).to eq "body\r\n"
      end

      it "leaves non-whitespace characters untouched" do
        body = "héllo  wörld ✓ \r\n"
        expect(canonical_body("\r\n\r\n#{body}")).to eq "héllo wörld ✓\r\n"
      end

      it "works on binary encoded input" do
        body = "héllo  wörld\r\n\r\n".b
        expect(canonical_body("From: a@example.com\r\n\r\n".b + body)).to eq "héllo wörld\r\n".b
      end

      it "does not strip non-whitespace control characters" do
        expect(canonical_body("\r\n\r\nbody\x00\r\n")).to eq "body\x00\r\n"
      end

      it "canonicalises a whitespace-only body as an empty string" do
        expect(canonical_body("\r\n\r\n  \r\n\t\r\n \r\n")).to eq ""
      end

      it "canonicalises an empty body as an empty string" do
        expect(canonical_body("From: a@example.com\r\n\r\n")).to eq ""
      end

      it "canonicalises a message with no header/body separator as an empty body" do
        expect(canonical_body("From: a@example.com\r\nSubject: Hi\r\n")).to eq ""
      end

      it "exposes the canonical body via the bh= tag" do
        message = "From: a@example.com\r\n\r\nhello \t  world   \r\n\r\n\r\n"
        tags = dkim_tags(build(message).dkim_header)
        expect(tags["bh"]).to eq body_hash_of("hello world\r\n")
      end
    end

    describe "header canonicalisation" do
      it "downcases header field names" do
        expect(canonical_headers("SUBJect: AbC\r\n\r\n")).to eq ["subject:AbC"]
      end

      it "does not change the case of header values" do
        expect(canonical_headers("From: John DOE <John@Example.COM>\r\n\r\n")).to eq ["from:John DOE <John@Example.COM>"]
      end

      it "removes whitespace after the colon" do
        expect(canonical_headers("Subject:   \t Hello\r\n\r\n")).to eq ["subject:Hello"]
      end

      it "handles a header with no whitespace after the colon" do
        expect(canonical_headers("Subject:Hello\r\n\r\n")).to eq ["subject:Hello"]
      end

      it "removes trailing whitespace from the value" do
        expect(canonical_headers("Subject: Hello   \t \r\n\r\n")).to eq ["subject:Hello"]
      end

      it "reduces internal runs of whitespace to a single space" do
        expect(canonical_headers("Subject: Hello \t  there   world\r\n\r\n")).to eq ["subject:Hello there world"]
      end

      it "unfolds a continuation line starting with a space" do
        expect(canonical_headers("Subject: Hello\r\n there\r\n\r\n")).to eq ["subject:Hello there"]
      end

      it "unfolds a continuation line starting with a tab" do
        expect(canonical_headers("Subject: Hello\r\n\tthere\r\n\r\n")).to eq ["subject:Hello there"]
      end

      it "unfolds multiple continuation lines" do
        message = "Subject: one\r\n two\r\n\tthree\r\n \t four\r\n\r\n"
        expect(canonical_headers(message)).to eq ["subject:one two three four"]
      end

      it "unfolds continuation lines with LF line endings" do
        expect(canonical_headers("Subject: Hello\n there\n\n")).to eq ["subject:Hello there"]
      end

      it "reduces whitespace on a continuation line to a single space" do
        expect(canonical_headers("Subject: Hello\r\n      \t there\r\n\r\n")).to eq ["subject:Hello there"]
      end

      it "unfolds a header whose value starts on a continuation line" do
        expect(canonical_headers("Subject:\r\n Hello\r\n\r\n")).to eq ["subject:Hello"]
      end

      it "produces an empty value for a header with no value" do
        expect(canonical_headers("Subject:\r\n\r\n")).to eq ["subject:"]
      end

      it "produces an empty value for a header with a whitespace-only value" do
        expect(canonical_headers("Subject:   \t\r\n\r\n")).to eq ["subject:"]
      end

      it "only splits the name from the value on the first colon" do
        expect(canonical_headers("Subject: Re: a:b :c\r\n\r\n")).to eq ["subject:Re: a:b :c"]
      end

      it "derives the signed header name from the text before the first colon" do
        expect(signed_header_names("Subject: Re: a:b\r\n\r\n")).to eq ["subject"]
      end

      it "leaves non-ASCII header values untouched" do
        expect(canonical_headers("Subject: héllo  wörld\r\n\r\n")).to eq ["subject:héllo wörld"]
      end

      it "does not modify headers which are not signed" do
        header = build("X-Custom: Hello \t there   \r\n\r\n").send(:headers)
        expect(header).to eq ["X-Custom: Hello \t there   "]
      end

      it "signs the canonical form of the headers" do
        message = "FROM:   John  <john@example.com>  \r\nSubject: Hello\r\n\tthere\r\nX-Ignored: x\r\n\r\nbody\r\n"
        header = build(message).dkim_header
        tags = dkim_tags(header)
        signable = [
          "from:John <john@example.com>",
          "subject:Hello there",
          "dkim-signature:v=1; a=rsa-sha256; c=relaxed/relaxed; d=example.com; s=postal; t=#{tags['t']}; bh=#{tags['bh']}; h=from:subject; b=",
        ].join("\r\n")
        signature = Base64.decode64(tags["b"])
        expect(private_key.public_key.verify(OpenSSL::Digest.new("SHA256"), signature, signable)).to be true
      end
    end

    describe "signed header selection" do
      signable = %w[From Sender Reply-To Subject Date Message-ID To Cc MIME-Version Content-Type
                    Content-Transfer-Encoding Resent-To Resent-Cc Resent-From Resent-Sender Resent-Message-ID
                    In-Reply-To References List-ID List-Help List-Owner List-Unsubscribe List-Unsubscribe-Post
                    List-Subscribe List-Post]

      signable.each do |name|
        it "signs the #{name} header" do
          expect(signed_header_names("#{name}: value\r\n\r\n")).to eq [name.downcase]
        end

        it "signs the #{name} header regardless of case" do
          expect(signed_header_names("#{name.upcase}: value\r\nX-Other: x\r\n#{name.downcase}: value\r\n\r\n")).to eq [name.downcase, name.downcase]
        end
      end

      %w[Received Return-Path Bcc DKIM-Signature X-Postal-MsgID X-Mailer Authentication-Results
         Delivered-To Comments Keywords].each do |name|
        it "does not sign the #{name} header" do
          expect(signed_header_names("#{name}: value\r\n\r\n")).to eq []
        end
      end

      %w[Fromage From-Address Subject-Hash To-Do Sender-Id Date-Sent CcX References-Old List-Idx
         List-Unsubscribe-Postx Reply-To-Name].each do |name|
        it "does not sign the #{name} header even though it starts with a signed header name" do
          expect(signed_header_names("#{name}: value\r\n\r\n")).to eq []
        end
      end

      %w[X-From Old-Subject Resent-Date Original-To Auto-Cc Sub-Reply-To].each do |name|
        it "does not sign the #{name} header even though it ends with a signed header name" do
          expect(signed_header_names("#{name}: value\r\n\r\n")).to eq []
        end
      end

      it "does not sign a header with whitespace between the name and the colon" do
        expect(signed_header_names("From : value\r\n\r\n")).to eq []
      end

      it "does not sign a header without a colon" do
        expect(signed_header_names("From value\r\n\r\n")).to eq []
      end

      it "does not sign a header name that only appears in a folded value" do
        message = "Received: from mail.example.com\r\n from: someone@example.com\r\n\r\n"
        expect(signed_header_names(message)).to eq []
      end

      it "does not sign a header name that appears mid-value" do
        expect(signed_header_names("X-Info: from: a@example.com subject: hi\r\n\r\n")).to eq []
      end

      it "signs a header name followed immediately by its value" do
        expect(signed_header_names("From:a@example.com\r\n\r\n")).to eq ["from"]
      end

      it "signs List-Unsubscribe-Post distinctly from List-Unsubscribe" do
        message = "List-Unsubscribe-Post: List-Unsubscribe=One-Click\r\nList-Unsubscribe: <mailto:x@example.com>\r\n\r\n"
        expect(signed_header_names(message)).to eq ["list-unsubscribe-post", "list-unsubscribe"]
      end

      it "includes duplicate headers once for each occurrence" do
        message = "To: a@example.com\r\nSubject: Hi\r\nTo: b@example.com\r\n\r\n"
        expect(signed_header_names(message)).to eq %w[to subject to]
        expect(canonical_headers(message)).to eq ["to:a@example.com", "subject:Hi", "to:b@example.com"]
      end

      it "keeps headers in message order" do
        message = "Subject: Hi\r\nDate: Mon, 1 Jan 2024 00:00:00 +0000\r\nFrom: a@example.com\r\nTo: b@example.com\r\n\r\n"
        expect(signed_header_names(message)).to eq %w[subject date from to]
      end

      it "lists the signed headers in the h= tag" do
        message = "Received: x\r\nFrom: a@example.com\r\nTo: b@example.com\r\nX-Other: x\r\nSubject: Hi\r\n\r\nbody"
        expect(dkim_tags(build(message).dkim_header)["h"]).to eq "from:to:subject"
      end

      it "produces an empty h= tag when no signable headers are present" do
        message = "Received: x\r\nX-Other: x\r\n\r\nbody"
        expect(dkim_tags(build(message).dkim_header)["h"]).to eq ""
      end
    end

    describe "#dkim_header" do
      let(:message) { "From: a@example.com\r\nTo: b@example.com\r\nSubject: Hi\r\n\r\nbody\r\n" }

      it "wraps the signature onto lines of at most 72 characters" do
        header = build(message).dkim_header
        signature_lines = header.split("\r\n\t").drop_while { |line| !line.start_with?("b=") }
        signature_lines[0] = signature_lines[0].sub("b=", "")
        expect(signature_lines.size).to be > 1
        expect(signature_lines.map(&:length)).to all(be <= 72)
        expect(signature_lines.map(&:length)[0..-2]).to all(eq 72)
        expect(Base64.decode64(signature_lines.join).bytesize).to eq 128
      end

      it "does not include newlines in the signature" do
        header = build(message).dkim_header
        expect(dkim_tags(header)["b"]).to match(/\A[A-Za-z0-9+\/=]+\z/)
      end

      it "lays the tags out on folded lines" do
        Timecop.freeze do
          header = build(message).dkim_header
          expect(header).to start_with(
            "DKIM-Signature: v=1; a=rsa-sha256; c=relaxed/relaxed;\r\n" \
            "\td=example.com;\r\n" \
            "\ts=postal; t=#{Time.now.utc.to_i};\r\n" \
            "\tbh=#{body_hash_of("body\r\n")};\r\n" \
            "\th=from:to:subject;\r\n" \
            "\tb="
          )
        end
      end

      it "signs with the return path domain when the domain has no valid DKIM record" do
        unverified = instance_double("Domain", dkim_status: "Missing")
        tags = dkim_tags(described_class.new(unverified, message).dkim_header)
        expect(tags["d"]).to eq Postal::Config.dns.return_path_domain
        expect(tags["s"]).to eq Postal::Config.dns.dkim_identifier
        signable = [
          "from:a@example.com",
          "to:b@example.com",
          "subject:Hi",
          "dkim-signature:v=1; a=rsa-sha256; c=relaxed/relaxed; d=#{tags['d']}; s=#{tags['s']}; t=#{tags['t']}; bh=#{tags['bh']}; h=from:to:subject; b=",
        ].join("\r\n")
        public_key = Postal.signer.private_key.public_key
        expect(public_key.verify(OpenSSL::Digest.new("SHA256"), Base64.decode64(tags["b"]), signable)).to be true
      end

      it "signs with the return path domain when there is no domain" do
        tags = dkim_tags(described_class.new(nil, message).dkim_header)
        expect(tags["d"]).to eq Postal::Config.dns.return_path_domain
      end
    end
  end
end
