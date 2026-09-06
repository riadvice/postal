# frozen_string_literal: true

require "rails_helper"

RSpec.describe Postal::MessageDB::Message do
  let(:server) { create(:server) }

  def message_with_raw(raw)
    message = server.message_db.new_message
    message.scope = "incoming"
    message.rcpt_to = "test@example.com"
    message.mail_from = "john@example.com"
    message.raw_message = raw.dup
    message.save(queue_on_create: false)
    message
  end

  describe "#attachments" do
    context "when the message is multipart with a real attachment" do
      let(:message) do
        MessageFactory.incoming(server) do |_msg, mail|
          mail.add_file(filename: "doc.txt", content: "hello attachment")
        end
      end

      it "returns the attachment" do
        expect(message.attachments.size).to eq 1
        expect(message.attachments.first.filename).to eq "doc.txt"
      end
    end

    context "when the message is a normal plain text message with no attachment" do
      let(:message) { MessageFactory.incoming(server) }

      it "returns no attachments" do
        expect(message.attachments).to eq []
      end
    end

    context "when the message is a non-multipart HTML body that merely names itself" do
      let(:message) do
        MessageFactory.incoming(server) do |_msg, mail|
          mail.content_type = 'text/html; name="newsletter.html"'
          mail.body = "<p>hello</p>"
        end
      end

      it "is not treated as an attachment" do
        expect(message.attachments).to eq []
      end
    end

    context "when the message is not multipart and its entire body is the attachment" do
      let(:message) do
        MessageFactory.incoming(server) do |_msg, mail|
          mail.content_type = "application/pdf"
          mail.content_disposition = 'attachment; filename="doc.pdf"'
          mail.body = "raw pdf bytes"
        end
      end

      it "treats the whole body as a single attachment" do
        expect(message.attachments.size).to eq 1
        attachment = message.attachments.first
        expect(attachment.filename).to eq "doc.pdf"
        expect(attachment.mime_type).to eq "application/pdf"
        expect(attachment.body.to_s).to eq "raw pdf bytes"
      end
    end
  end

  describe "#copy_attributes_from_raw_message" do
    def message_with_headers(*headers)
      message_with_raw("From: john@example.com\r\nTo: test@example.com\r\n#{headers.join("\r\n")}\r\n\r\nHello\r\n")
    end

    describe "message id" do
      it "strips the angle brackets from the message id" do
        expect(message_with_headers("Message-ID: <abc@example.com>").message_id).to eq "abc@example.com"
      end

      it "extracts a message id which has no angle brackets" do
        expect(message_with_headers("Message-ID: abc@example.com").message_id).to eq "abc@example.com"
      end

      it "strips surrounding whitespace" do
        expect(message_with_headers("Message-ID:    <abc@example.com>   ").message_id).to eq "abc@example.com"
      end

      it "strips a leading comment" do
        expect(message_with_headers("Message-ID: (comment) <abc@example.com>").message_id).to eq "abc@example.com"
      end

      it "strips a trailing comment" do
        expect(message_with_headers("Message-ID: <abc@example.com> (comment)").message_id).to eq "abc@example.com"
      end

      it "extracts a folded message id" do
        expect(message_with_headers("Message-ID:\r\n <abc@example.com>").message_id).to eq "abc@example.com"
      end

      it "extracts a message id which does not contain an @" do
        expect(message_with_headers("Message-ID: <no-at-sign>").message_id).to eq "no-at-sign"
      end

      it "extracts a message id which contains spaces" do
        expect(message_with_headers("Message-ID: <weird stuff here>").message_id).to eq "weird stuff here"
      end

      it "keeps the message id case" do
        expect(message_with_headers("Message-ID: <AbC@Example.COM>").message_id).to eq "AbC@Example.COM"
      end

      it "uses the last message id when there are several" do
        message = message_with_headers("Message-Id: <first@example.com>", "Message-ID: <second@example.com>")
        expect(message.message_id).to eq "second@example.com"
      end

      it "returns an empty message id for an empty pair of angle brackets" do
        expect(message_with_headers("Message-ID: <>").message_id).to eq ""
      end

      it "returns nil when there is no message id" do
        expect(message_with_headers.message_id).to be_nil
      end

      it "matches the header name case-insensitively" do
        expect(message_with_headers("message-id: <abc@example.com>").message_id).to eq "abc@example.com"
      end
    end

    describe "subject" do
      it "copies the subject" do
        expect(message_with_headers("Subject: Hello world").subject).to eq "Hello world"
      end

      it "returns an empty subject when there is no subject" do
        expect(message_with_headers.subject).to eq ""
      end

      it "truncates the subject to 200 characters" do
        expect(message_with_headers("Subject: #{'a' * 300}").subject).to eq "a" * 200
      end

      it "does not truncate a subject of exactly 200 characters" do
        expect(message_with_headers("Subject: #{'a' * 200}").subject).to eq "a" * 200
      end

      it "truncates to 200 characters rather than bytes for multibyte subjects" do
        message = MessageFactory.incoming(server) do |_msg, mail|
          mail.subject = "é" * 250
        end
        expect(message.subject.length).to eq 200
        expect(message.subject).to eq "é" * 200
      end

      it "decodes encoded-word subjects" do
        expect(message_with_headers("Subject: =?UTF-8?Q?=C3=A9t=C3=A9?=").subject).to eq "été"
      end

      it "unfolds a folded subject" do
        expect(message_with_headers("Subject: Hello\r\n world").subject).to eq "Hello world"
      end

      it "uses the last subject when there are several" do
        expect(message_with_headers("Subject: First", "Subject: Second").subject).to eq "Second"
      end
    end
  end

  describe "#has_outgoing_headers?" do
    let(:message) { MessageFactory.outgoing(server) }

    it "is false for a message without the postal header" do
      expect(message.has_outgoing_headers?).to be false
    end

    it "is true once the outgoing headers have been added" do
      message.add_outgoing_headers
      expect(message.has_outgoing_headers?).to be true
    end

    it "is true when the header is present" do
      message.append_headers("X-Postal-MsgID: abc123")
      expect(message.has_outgoing_headers?).to be true
    end

    it "matches the header name case-insensitively" do
      message.append_headers("x-postal-msgid: abc123")
      expect(message.has_outgoing_headers?).to be true
    end

    it "matches when the header is not the first header" do
      message.append_headers("X-Other: value", "X-Postal-MsgID: abc123")
      expect(message.has_outgoing_headers?).to be true
    end

    it "does not match the header name inside another header's value" do
      message.append_headers("X-Other: X-Postal-MsgID: abc123")
      expect(message.has_outgoing_headers?).to be false
    end

    it "does not match a header with a longer name" do
      message.append_headers("X-Postal-MsgID-Old: abc123")
      expect(message.has_outgoing_headers?).to be false
    end

    it "does not match a folded continuation line" do
      message.append_headers("X-Other: value\r\n X-Postal-MsgID: abc123")
      expect(message.has_outgoing_headers?).to be false
    end
  end

  describe "#original_messages" do
    let(:original) { MessageFactory.outgoing(server) }

    def bounce_with_body(body)
      MessageFactory.incoming(server) do |msg, mail|
        msg.bounce = true
        mail.body = body
      end
    end

    it "returns nil when the message is not a bounce" do
      message = MessageFactory.incoming(server) do |_msg, mail|
        mail.body = "X-Postal-MsgID: #{original.token}"
      end
      expect(message.original_messages).to be_nil
    end

    it "returns an empty array when no postal message id is present" do
      expect(bounce_with_body("Nothing to see here").original_messages).to eq []
    end

    it "finds the original message referenced in the bounce" do
      bounce = bounce_with_body("Original headers:\r\nX-Postal-MsgID: #{original.token}\r\nSubject: x")
      expect(bounce.original_messages.map(&:id)).to eq [original.id]
    end

    it "matches the header name case-insensitively" do
      bounce = bounce_with_body("x-postal-msgid: #{original.token}")
      expect(bounce.original_messages.map(&:id)).to eq [original.id]
    end

    it "allows no whitespace between the colon and the token" do
      bounce = bounce_with_body("X-Postal-MsgID:#{original.token}")
      expect(bounce.original_messages.map(&:id)).to eq [original.id]
    end

    it "allows the token to be on a folded continuation line" do
      bounce = bounce_with_body("X-Postal-MsgID:\r\n  #{original.token}")
      expect(bounce.original_messages.map(&:id)).to eq [original.id]
    end

    it "stops the token at the first non-alphanumeric character" do
      bounce = bounce_with_body("X-Postal-MsgID: #{original.token}; something else")
      expect(bounce.original_messages.map(&:id)).to eq [original.id]
    end

    it "finds several original messages" do
      other = MessageFactory.outgoing(server)
      bounce = bounce_with_body("X-Postal-MsgID: #{original.token}\r\nX-Postal-MsgID: #{other.token}")
      expect(bounce.original_messages.map(&:id)).to contain_exactly(original.id, other.id)
    end

    it "returns an empty array when the token does not match any message" do
      expect(bounce_with_body("X-Postal-MsgID: nonexistenttoken1").original_messages).to eq []
    end

    it "does not match a header with a different prefix" do
      bounce = bounce_with_body("Y-Postal-MsgID: #{original.token}")
      expect(bounce.original_messages).to eq []
    end
  end

  describe "#rcpt_to_return_path?" do
    let(:prefix) { Postal::Config.dns.custom_return_path_prefix }

    def message_to(rcpt_to)
      message = server.message_db.new_message
      message.rcpt_to = rcpt_to
      message
    end

    it "is true for an address at the custom return path prefix" do
      expect(message_to("abc@#{prefix}.example.com").rcpt_to_return_path?).to be true
    end

    it "is true for a custom return path with a nested domain" do
      expect(message_to("abc@#{prefix}.mail.example.com").rcpt_to_return_path?).to be true
    end

    it "is true for a bare token local part" do
      expect(message_to("#{prefix}@#{prefix}.example.com").rcpt_to_return_path?).to be true
    end

    it "is false for a normal address" do
      expect(message_to("abc@example.com").rcpt_to_return_path?).to be false
    end

    it "is false when the prefix is not directly after the @" do
      expect(message_to("abc@x#{prefix}.example.com").rcpt_to_return_path?).to be false
    end

    it "is false when the prefix is not followed by a dot" do
      expect(message_to("abc@#{prefix}-example.com").rcpt_to_return_path?).to be false
      expect(message_to("abc@#{prefix}example.com").rcpt_to_return_path?).to be false
    end

    it "is false when the prefix only appears in the local part" do
      expect(message_to("#{prefix}.abc@example.com").rcpt_to_return_path?).to be false
    end

    it "is false when the prefix only appears in the middle of the domain" do
      expect(message_to("abc@mail.#{prefix}.example.com").rcpt_to_return_path?).to be false
    end

    it "is false when there is no recipient" do
      expect(message_to(nil).rcpt_to_return_path?).to be false
    end

    it "is false for an empty recipient" do
      expect(message_to("").rcpt_to_return_path?).to be false
    end

    context "when the prefix contains regular expression characters" do
      before do
        allow(Postal::Config.dns).to receive(:custom_return_path_prefix).and_return("rp.x")
      end

      it "matches the prefix literally" do
        expect(message_to("abc@rp.x.example.com").rcpt_to_return_path?).to be true
      end

      it "does not treat the dot as a wildcard" do
        expect(message_to("abc@rpzx.example.com").rcpt_to_return_path?).to be false
      end
    end
  end

  describe "#html_body_without_tracking_image" do
    def message_with_html(html)
      MessageFactory.incoming(server) do |_msg, mail|
        mail.content_type = "text/html; charset=UTF-8"
        mail.body = html
      end
    end

    let(:tracking_image) do
      "<p class='ampimg' style='display:none;visibility:none;margin:0;padding:0;line-height:0;'><img src='https://track.example.com/img/abc/def' alt=''></p>"
    end

    it "removes the tracking image paragraph" do
      message = message_with_html("<html><body><p>Hello</p>#{tracking_image}</body></html>")
      expect(message.html_body_without_tracking_image).to eq "<html><body><p>Hello</p></body></html>"
    end

    it "removes a tracking image paragraph using double quotes" do
      message = message_with_html("<p>Hello</p><p class=\"ampimg\"><img src=\"x\"></p>")
      expect(message.html_body_without_tracking_image).to eq "<p>Hello</p>"
    end

    it "only removes up to the first closing paragraph tag" do
      message = message_with_html("#{tracking_image}<p>Keep me</p>")
      expect(message.html_body_without_tracking_image).to eq "<p>Keep me</p>"
    end

    it "removes several tracking image paragraphs" do
      message = message_with_html("#{tracking_image}<p>Keep me</p>#{tracking_image}")
      expect(message.html_body_without_tracking_image).to eq "<p>Keep me</p>"
    end

    it "does not remove paragraphs with a different class" do
      message = message_with_html("<p class='ampimg2'>Keep</p><p class='notampimg'>Keep</p>")
      expect(message.html_body_without_tracking_image).to eq "<p class='ampimg2'>Keep</p><p class='notampimg'>Keep</p>"
    end

    it "does not remove a paragraph with the class name in its content" do
      message = message_with_html("<p>class='ampimg'</p>")
      expect(message.html_body_without_tracking_image).to eq "<p>class='ampimg'</p>"
    end

    it "returns the body unchanged when there is no tracking image" do
      message = message_with_html("<p>Hello</p>")
      expect(message.html_body_without_tracking_image).to eq "<p>Hello</p>"
    end
  end

  describe "attribute accessors" do
    let(:message) { server.message_db.new_message("subject" => "Hello") }

    it "reads known attributes" do
      expect(message.subject).to eq "Hello"
    end

    it "writes attributes using a setter" do
      message.subject = "Changed"
      expect(message.subject).to eq "Changed"
    end

    it "creates new attributes using a setter" do
      message.custom_thing = 1
      expect(message.custom_thing).to eq 1
    end

    it "returns nil for unknown attributes" do
      expect(message.unknown).to be_nil
    end

    it "responds to known attributes and their setters" do
      expect(message.respond_to?(:subject)).to be true
      expect(message.respond_to?(:subject=)).to be true
    end

    it "does not respond to unknown attributes" do
      expect(message.respond_to?(:unknown)).to be false
      expect(message.respond_to?(:unknown=)).to be false
    end
  end
end
