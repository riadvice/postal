# frozen_string_literal: true

require "rails_helper"

describe Postal::MessageParser do
  let(:server) { create(:server) }

  it "should not do anything when there are no tracking domains" do
    expect(server.track_domains.size).to eq 0
    message = create_plain_text_message(server, "Hello world!", "test@example.com")
    parser = Postal::MessageParser.new(message)
    expect(parser.actioned?).to be false
    expect(parser.tracked_links).to eq 0
    expect(parser.tracked_images).to eq 0
  end

  it "should replace links in messages" do
    message = create_plain_text_message(server, "Hello world! http://github.com/atech/postal", "test@example.com")
    create(:track_domain, server: server, domain: message.domain)
    parser = Postal::MessageParser.new(message)
    expect(parser.actioned?).to be true
    expect(parser.new_body).to match(/^Hello world! https:\/\/click\.#{message.domain.name}/)
    expect(parser.tracked_links).to eq 1
  end

  it "should strip the +notrack marker even when the track domain's DNS isn't OK" do
    message = create_plain_text_message(server, "Hello world! http+notrack://github.com/atech/postal", "test@example.com")
    create(:track_domain, server: server, domain: message.domain, dns_status: "Missing")
    parser = Postal::MessageParser.new(message)
    expect(parser.actioned?).to be true
    expect(parser.new_body).not_to include("+notrack")
    expect(parser.new_body).to include("http://github.com/atech/postal")
    expect(parser.tracked_links).to eq 0
  end
end
