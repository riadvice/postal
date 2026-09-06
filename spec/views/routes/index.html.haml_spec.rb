# frozen_string_literal: true

require "rails_helper"

RSpec.describe "routes/index", type: :view do
  let(:organization) { create(:organization) }
  let(:server) { create(:server, organization: organization) }
  let(:domain) { create(:domain, owner: server) }

  before do
    stub_template "servers/_sidebar.html.haml" => ""
    stub_template "servers/_header.html.haml" => ""
    stub_template "routes/_header.html.haml" => ""
    org = organization
    view.define_singleton_method(:organization) { org }
    view.define_singleton_method(:page_title) { @page_title ||= [] }
    assign(:server, server)
  end

  context "when a route has a dangling reference to a deleted endpoint" do
    before do
      route = create(:route, server: server, domain: domain, mode: "Endpoint", endpoint: create(:http_endpoint, server: server))
      route.update_column(:endpoint_id, 0)
      assign(:routes, server.routes.includes(:domain, :endpoint).to_a)
    end

    it "renders without raising" do
      expect { render }.not_to raise_error
    end

    it "shows a placeholder instead of crashing" do
      render
      expect(rendered).to include("Missing endpoint")
    end
  end

  context "when a route has a normal, valid endpoint" do
    before do
      endpoint = create(:http_endpoint, server: server, name: "My endpoint")
      create(:route, server: server, domain: domain, mode: "Endpoint", endpoint: endpoint)
      assign(:routes, server.routes.includes(:domain, :endpoint).to_a)
    end

    it "shows the endpoint description" do
      render
      expect(rendered).to include("My endpoint")
    end
  end
end
