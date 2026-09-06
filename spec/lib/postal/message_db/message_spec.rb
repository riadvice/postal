# frozen_string_literal: true

require "rails_helper"

RSpec.describe Postal::MessageDB::Message do
  let(:server) { create(:server) }

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

    context "when the message is not multipart and its entire body is the attachment" do
      let(:message) do
        MessageFactory.incoming(server) do |_msg, mail|
          mail.content_type = "application/pdf"
          mail.content_disposition = 'attachment; filename="doc.pdf"'
          mail.body = "raw pdf bytes"
        end
      end

      it "treats the whole body as a single attachment" do
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

        expect(message.attachments.size).to eq 1
        attachment = message.attachments.first
        expect(attachment.filename).to eq "doc.pdf"
        expect(attachment.mime_type).to eq "application/pdf"
        expect(attachment.body.to_s).to eq "raw pdf bytes"
      end
    end
  end
end
