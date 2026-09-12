# frozen_string_literal: true

require "rails_helper"

RSpec.describe "MessagesController", type: :request do
  let(:user) { create(:user, admin: true) }
  let(:organization) { create(:organization, owner: user) }
  let(:server) { create(:server, organization: organization) }

  before do
    post "/login", params: { email_address: user.email_address, password: "passw0rd" }
  end

  describe "GET /org/:org/servers/:server/messages/:id/html_raw" do
    let(:xss_payload) { %(<script>alert("XSS")</script>) }
    let(:message) do
      payload = xss_payload
      MessageFactory.incoming(server) do |_msg, mail|
        mail.html_part = Mail::Part.new do
          content_type "text/html; charset=UTF-8"
          body %(<html><body><p>hello</p>#{payload}</body></html>)
        end
      end
    end

    before do
      get "/org/#{organization.permalink}/servers/#{server.permalink}/messages/#{message.id}/html_raw"
    end

    it "returns the stored email HTML" do
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("hello")
    end

    it "serves a restrictive Content-Security-Policy that blocks scripts" do
      csp = response.headers["Content-Security-Policy"]
      expect(csp).to include("script-src 'none'")
      expect(csp).to include("default-src 'none'")
      expect(csp).to include("form-action 'none'")
      expect(csp).to include("base-uri 'none'")
    end

    it "sets X-Content-Type-Options and Referrer-Policy on the response" do
      expect(response.headers["X-Content-Type-Options"]).to eq "nosniff"
      expect(response.headers["Referrer-Policy"]).to eq "no-referrer"
    end
  end

  describe "#get_time_from_string" do
    def time_from(string)
      MessagesController.new.send(:get_time_from_string, string)
    end

    it "parses a date with a time" do
      expect(time_from("2024-01-15 13:45")).to eq Time.new(2024, 1, 15, 13, 45)
    end

    it "parses a date without a time as midnight" do
      expect(time_from("2024-01-15")).to eq Time.new(2024, 1, 15, 0)
    end

    it "falls back to natural language parsing for other formats" do
      expect(time_from("2024-1-5").to_date).to eq Date.new(2024, 1, 5)
      expect(time_from("2024-01-15T13:45")).to eq Time.new(2024, 1, 15, 13, 45)
      expect(time_from("2024-01-15 13:45:00")).to eq Time.new(2024, 1, 15, 13, 45)
      expect(time_from("15th January 2024").to_date).to eq Date.new(2024, 1, 15)
    end

    it "falls back to natural language parsing when there is trailing whitespace" do
      expect(time_from("2024-01-15\n").to_date).to eq Date.new(2024, 1, 15)
      expect(time_from("2024-01-15 13:45 ").to_date).to eq Date.new(2024, 1, 15)
    end

    it "parses relative times in the past" do
      Timecop.freeze(Time.new(2024, 6, 1, 12, 0)) do
        expect(time_from("yesterday").to_date).to eq Date.new(2024, 5, 31)
      end
    end

    it "raises when the date is impossible" do
      expect { time_from("2024-13-45") }.to raise_error(MessagesController::TimeUndetermined)
      expect { time_from("2024-01-15 25:61") }.to raise_error(MessagesController::TimeUndetermined)
    end

    it "raises when the string cannot be understood" do
      expect { time_from("not a date") }.to raise_error(MessagesController::TimeUndetermined, /not a date/)
      expect { time_from("") }.to raise_error(MessagesController::TimeUndetermined)
      expect { time_from("2024-01-15'; DROP TABLE messages; --") }.to raise_error(MessagesController::TimeUndetermined)
    end

    it "interprets a two digit year as the current century" do
      expect(time_from("24-01-15")).to eq Time.new(2024, 1, 15, 0)
      expect(time_from("24-01-15 10:30")).to eq Time.new(2024, 1, 15, 10, 30)
    end
  end

  describe "GET /org/:org/servers/:server/messages/incoming (filtering)" do
    let!(:invoice_message) do
      MessageFactory.incoming(server) do |msg, mail|
        mail.subject = "Your invoice is ready"
        msg.rcpt_to = "rachel@example.com"
        msg.tag = "invoices"
      end
    end

    let!(:other_message) do
      MessageFactory.incoming(server) do |msg, mail|
        mail.subject = "Welcome aboard"
        msg.rcpt_to = "someone-else@example.com"
      end
    end

    def region_html_for(query)
      get incoming_organization_server_messages_path(organization, server, query: query), as: :json
      JSON.parse(response.body)["region_html"]
    end

    it "filters by a subject 'contains' wildcard" do
      html = region_html_for("subject: *invoice*")
      expect(html).to include("Your invoice is ready")
      expect(html).not_to include("Welcome aboard")
    end

    it "filters by a to 'starts_with' wildcard" do
      html = region_html_for("to: rachel*")
      expect(html).to include("rachel@example.com")
      expect(html).not_to include("someone-else@example.com")
    end

    it "still supports an exact (non-wildcard) match" do
      html = region_html_for("to: rachel@example.com")
      expect(html).to include("rachel@example.com")
      expect(html).not_to include("someone-else@example.com")
    end

    it "filters by tag" do
      html = region_html_for("tag: invoices")
      expect(html).to include("Your invoice is ready")
      expect(html).not_to include("Welcome aboard")
    end

    it "warns about an unrecognized filter key instead of silently ignoring it" do
      get incoming_organization_server_messages_path(organization, server, query: "subjectt: invoice"), as: :json
      expect(JSON.parse(response.body)["flash"]["alert"]).to match(/Unrecognized filter.*subjectt/)
    end

    it "does not warn when every key is recognized" do
      get incoming_organization_server_messages_path(organization, server, query: "subject: invoice"), as: :json
      expect(JSON.parse(response.body)["flash"]).not_to have_key("alert")
    end
  end

  describe "GET /org/:org/servers/:server/messages/filter_values" do
    it "returns the known status values" do
      get filter_values_organization_server_messages_path(organization, server, field: "status")
      json = JSON.parse(response.body)
      expect(json["values"]).to include("Held", "Bounced")
    end

    it "returns yes/no for boolean fields" do
      get filter_values_organization_server_messages_path(organization, server, field: "held")
      json = JSON.parse(response.body)
      expect(json["values"]).to eq(%w[Yes No])
    end

    it "returns distinct tags used on the server" do
      MessageFactory.incoming(server) { |msg, _mail| msg.tag = "password-reset" }
      get filter_values_organization_server_messages_path(organization, server, field: "tag")
      json = JSON.parse(response.body)
      expect(json["values"]).to include("password-reset")
    end

    it "returns an empty array for an unknown field" do
      get filter_values_organization_server_messages_path(organization, server, field: "bogus")
      json = JSON.parse(response.body)
      expect(json["values"]).to eq([])
    end
  end

  describe "messages/html view template" do
    # We assert against the template source rather than rendering it in a
    # request spec because the full application layout depends on the asset
    # pipeline which is not configured in this test environment.
    it "embeds the html_raw view inside a sandboxed iframe" do
      template = Rails.root.join("app/views/messages/html.html.haml").read
      expect(template).to match(/%iframe\{[^}]*:sandbox\s*=>/)
    end
  end
end
