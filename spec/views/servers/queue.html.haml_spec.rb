# frozen_string_literal: true

require "rails_helper"

# postalserver/postal#328 could not be reproduced, this pins the current behaviour
RSpec.describe "servers/queue", type: :view do
  let(:organization) { create(:organization) }
  let(:server) { create(:server, organization: organization) }

  before do
    stub_template "servers/_sidebar.html.haml" => ""
    stub_template "servers/_header.html.haml" => ""
    stub_template "messages/_header.html.haml" => ""
    org = organization
    view.define_singleton_method(:organization) { org }
    view.define_singleton_method(:page_title) { @page_title ||= [] }
    assign(:server, server)
  end

  context "when a queued message's underlying message no longer exists" do
    before do
      create(:queued_message, server: server, message_id: 999_999_999)
      messages = server.queued_messages.order(id: :desc).page(1).includes(:ip_address)
      assign(:messages, messages)
      assign(:messages_with_message, messages.include_message)
    end

    it "renders without raising" do
      expect { render }.not_to raise_error
    end

    it "shows a deleted-message placeholder instead of crashing" do
      render
      expect(rendered).to include("Deleted message #999999999")
    end
  end

  context "when a queued message has a real underlying message" do
    let(:message) { MessageFactory.incoming(server) }

    before do
      create(:queued_message, server: server, message: message)
      messages = server.queued_messages.order(id: :desc).page(1).includes(:ip_address)
      assign(:messages, messages)
      assign(:messages_with_message, messages.include_message)
    end

    it "renders the message" do
      render
      expect(rendered).to include(message.subject)
    end
  end
end
