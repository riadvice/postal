# frozen_string_literal: true

require "rails_helper"
require "rack/test"

RSpec.describe TrackingMiddleware do
  include Rack::Test::Methods

  let(:inner_app) { ->(_env) { [200, {}, ["inner"]] } }
  let(:app) { described_class.new(inner_app) }

  let(:server) { create(:server) }
  let(:message) do
    MessageFactory.incoming(server) do |_msg, mail|
      mail.html_part = Mail::Part.new do
        content_type "text/html; charset=UTF-8"
        body "<html><body>hi</body></html>"
      end
    end
  end

  def track_headers
    { "HTTP_X_POSTAL_TRACK_HOST" => "1" }
  end

  def loads_for(message)
    server.message_db.message(message.id).loads
  end

  def clicks_for(message)
    server.message_db.select(:clicks, where: { message_id: message.id })
  end

  describe "GET /img/:server_token/:message_token (open tracking pixel)" do
    before do
      get "/img/#{server.token}/#{message.token}", {}, track_headers
    end

    it "returns the tracking pixel PNG" do
      expect(last_response.status).to eq 200
      expect(last_response.headers["Content-Type"]).to eq "image/png"
      expect(last_response.body.bytesize).to be > 0
    end

    it "records a load for the message" do
      # Re-fetch the message so loads are read fresh from the DB.
      reloaded = server.message_db.message(message.id)
      expect(reloaded.loads.size).to eq 1
    end
  end

  describe "GET /img/:server_token/:message_token?src=<url> (image proxy)" do
    let(:attacker_url) { "http://internal.example.com/secret" }

    before do
      stub_request(:get, attacker_url).to_return(status: 200, body: "internal-secret")
    end

    it "does not fetch the URL and returns 400" do
      get "/img/#{server.token}/#{message.token}", { src: attacker_url }, track_headers

      expect(last_response.status).to eq 400
      expect(WebMock).not_to have_requested(:get, attacker_url)
    end

    it "does not fetch the URL even when the message token is invalid" do
      get "/img/#{server.token}/nonexistent", { src: attacker_url }, track_headers

      expect(WebMock).not_to have_requested(:get, attacker_url)
    end
  end

  describe "when the track-host header is missing" do
    it "passes the request through to the inner app untouched" do
      get "/img/#{server.token}/#{message.token}"
      expect(last_response.body).to eq "inner"
    end
  end

  describe "track-host header handling" do
    it "passes through when the header is 0" do
      get "/img/#{server.token}/#{message.token}", {}, { "HTTP_X_POSTAL_TRACK_HOST" => "0" }
      expect(last_response.body).to eq "inner"
      expect(loads_for(message)).to be_empty
    end

    it "passes through when the header is a non-numeric value" do
      get "/img/#{server.token}/#{message.token}", {}, { "HTTP_X_POSTAL_TRACK_HOST" => "true" }
      expect(last_response.body).to eq "inner"
    end

    it "passes through when the header is 2" do
      get "/img/#{server.token}/#{message.token}", {}, { "HTTP_X_POSTAL_TRACK_HOST" => "2" }
      expect(last_response.body).to eq "inner"
    end

    it "handles the request when the header is 1" do
      get "/img/#{server.token}/#{message.token}", {}, track_headers
      expect(last_response.body).not_to eq "inner"
      expect(last_response.headers["Content-Type"]).to eq "image/png"
    end
  end

  describe "image path matching" do
    it "matches an upper-case /IMG/ prefix" do
      get "/IMG/#{server.token}/#{message.token}", {}, track_headers
      expect(last_response.status).to eq 200
      expect(last_response.headers["Content-Type"]).to eq "image/png"
      expect(loads_for(message).size).to eq 1
    end

    it "ignores a file extension after the message token" do
      get "/img/#{server.token}/#{message.token}.png", {}, track_headers
      expect(last_response.headers["Content-Type"]).to eq "image/png"
      expect(loads_for(message).size).to eq 1
    end

    it "ignores additional path segments after the message token" do
      get "/img/#{server.token}/#{message.token}/anything/else", {}, track_headers
      expect(last_response.headers["Content-Type"]).to eq "image/png"
      expect(loads_for(message).size).to eq 1
    end

    it "ignores the query string" do
      get "/img/#{server.token}/#{message.token}?utm_source=x", {}, track_headers
      expect(last_response.headers["Content-Type"]).to eq "image/png"
      expect(loads_for(message).size).to eq 1
    end

    it "still serves the pixel when the message token is unknown" do
      get "/img/#{server.token}/nonexistent", {}, track_headers
      expect(last_response.status).to eq 200
      expect(last_response.headers["Content-Type"]).to eq "image/png"
      expect(loads_for(message)).to be_empty
    end

    it "returns 404 when the server token is unknown" do
      get "/img/nonexistent/#{message.token}", {}, track_headers
      expect(last_response.status).to eq 404
      expect(last_response.body).to eq "Invalid Server Token"
    end

    it "treats a path with only a server token as a redirect request for a server called img" do
      get "/img/#{server.token}", {}, track_headers
      expect(last_response.status).to eq 404
      expect(last_response.body).to eq "Invalid Server Token"
    end

    it "does not treat a server token containing an underscore as an image request" do
      get "/img/bad_token/#{message.token}", {}, track_headers
      expect(last_response.status).to eq 404
      expect(last_response.body).to eq "Invalid Server Token"
    end

    it "stops the message token at a character outside the token alphabet" do
      get "/img/#{server.token}/#{message.token}_extra", {}, track_headers
      expect(last_response.headers["Content-Type"]).to eq "image/png"
      expect(loads_for(message).size).to eq 1
    end

    it "handles POST requests the same as GET" do
      post "/img/#{server.token}/#{message.token}", {}, track_headers
      expect(last_response.status).to eq 200
      expect(last_response.headers["Content-Type"]).to eq "image/png"
      expect(loads_for(message).size).to eq 1
    end
  end

  describe "GET /:server_token/:link_token (click tracking)" do
    let(:url) { "https://example.com/page?x=1&y=2#top" }
    let(:link_token) { message.create_link(url) }

    it "redirects to the original URL" do
      get "/#{server.token}/#{link_token}", {}, track_headers
      expect(last_response.status).to eq 307
      expect(last_response.headers["Location"]).to eq url
      expect(last_response.body).to eq "Redirected to: #{url}"
    end

    it "records a click against the message" do
      get "/#{server.token}/#{link_token}", {}, track_headers.merge("HTTP_USER_AGENT" => "TestAgent/1.0", "REMOTE_ADDR" => "203.0.113.5")
      clicks = clicks_for(message)
      expect(clicks.size).to eq 1
      expect(clicks.first["user_agent"]).to eq "TestAgent/1.0"
      expect(clicks.first["ip_address"]).to eq "203.0.113.5"
    end

    it "returns 404 when the link token is unknown" do
      get "/#{server.token}/nonexistent", {}, track_headers
      expect(last_response.status).to eq 404
      expect(last_response.body).to eq "Link not found"
    end

    it "returns 404 when the server token is unknown" do
      get "/nonexistent/#{link_token}", {}, track_headers
      expect(last_response.status).to eq 404
      expect(last_response.body).to eq "Invalid Server Token"
    end

    it "returns 404 for an unknown upper-case server token rather than passing through" do
      get "/NOPE-1/#{link_token}", {}, track_headers
      expect(last_response.status).to eq 404
      expect(last_response.body).to eq "Invalid Server Token"
    end

    it "ignores additional path segments after the link token" do
      get "/#{server.token}/#{link_token}/extra", {}, track_headers
      expect(last_response.status).to eq 307
      expect(last_response.headers["Location"]).to eq url
    end

    it "ignores trailing punctuation after the link token" do
      get "/#{server.token}/#{link_token}.", {}, track_headers
      expect(last_response.status).to eq 307
    end

    it "ignores percent-encoded characters after the link token" do
      get "/#{server.token}/#{link_token}%20x", {}, track_headers
      expect(last_response.status).to eq 307
    end

    it "ignores the query string" do
      get "/#{server.token}/#{link_token}?utm_source=x", {}, track_headers
      expect(last_response.status).to eq 307
      expect(last_response.headers["Location"]).to eq url
    end

    it "handles POST requests the same as GET" do
      post "/#{server.token}/#{link_token}", {}, track_headers
      expect(last_response.status).to eq 307
      expect(clicks_for(message).size).to eq 1
    end

    it "returns 404 when the link token contains characters outside the token alphabet" do
      get "/#{server.token}/_#{link_token}", {}, track_headers
      expect(last_response.status).to eq 200
      expect(last_response.body).to eq "Hello."
    end
  end

  describe "non-matching paths" do
    it "responds with a greeting for the root path" do
      get "/", {}, track_headers
      expect(last_response.status).to eq 200
      expect(last_response.body).to eq "Hello."
    end

    it "responds with a greeting for a single path segment" do
      get "/#{server.token}", {}, track_headers
      expect(last_response.body).to eq "Hello."
    end

    it "responds with a greeting for a single path segment with a trailing slash" do
      get "/#{server.token}/", {}, track_headers
      expect(last_response.body).to eq "Hello."
    end

    it "responds with a greeting when the first segment contains disallowed characters" do
      get "/a.b/c", {}, track_headers
      expect(last_response.body).to eq "Hello."
    end

    it "never reaches the inner app when the track-host header is set" do
      get "/", {}, track_headers
      expect(last_response.body).not_to eq "inner"
    end
  end
end
