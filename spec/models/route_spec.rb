# frozen_string_literal: true

require "rails_helper"

RSpec.describe Route do
  describe "destroying the endpoint a route points to" do
    let(:server) { create(:server) }
    let(:domain) { create(:domain, owner: server) }
    let(:http_endpoint) { create(:http_endpoint, server: server) }

    context "when the route is a normal route" do
      let!(:route) do
        create(:route, server: server, domain: domain, mode: "Endpoint", endpoint: http_endpoint)
      end

      it "resets the route to Reject mode" do
        http_endpoint.destroy
        expect(route.reload.mode).to eq "Reject"
        expect(route.endpoint).to be_nil
      end
    end

    context "when the route is the return path route" do
      let!(:route) do
        create(:route, server: server, domain: nil, name: "__returnpath__", mode: "Endpoint", endpoint: http_endpoint)
      end

      it "does not destroy the endpoint" do
        http_endpoint.destroy
        expect(http_endpoint.reload).to be_persisted
      end

      it "adds an error explaining why the endpoint could not be deleted" do
        http_endpoint.destroy
        expect(http_endpoint.errors[:base]).to include("This endpoint is used by the return path route and cannot be deleted")
      end

      it "leaves the route pointing at the endpoint" do
        http_endpoint.destroy
        expect(route.reload.mode).to eq "Endpoint"
        expect(route.endpoint).to eq http_endpoint
      end
    end

    context "when the endpoint is an SMTP endpoint" do
      let(:smtp_endpoint) { create(:smtp_endpoint, server: server) }

      it "resets a normal route to Reject mode" do
        route = create(:route, server: server, domain: domain, mode: "Endpoint", endpoint: smtp_endpoint)
        smtp_endpoint.destroy
        expect(route.reload.mode).to eq "Reject"
        expect(route.endpoint).to be_nil
      end

      it "refuses to be destroyed while a return path route points at it" do
        route = build(:route, server: server, domain: nil, name: "__returnpath__", mode: "Endpoint", endpoint: smtp_endpoint)
        route.save(validate: false)
        expect(smtp_endpoint.destroy).to be false
        expect(smtp_endpoint.reload).to be_persisted
        expect(smtp_endpoint.errors[:base]).to include("This endpoint is used by the return path route and cannot be deleted")
      end
    end

    context "when the endpoint is an address endpoint" do
      let(:address_endpoint) { create(:address_endpoint, server: server) }

      it "resets a normal route to Reject mode" do
        route = create(:route, server: server, domain: domain, mode: "Endpoint", endpoint: address_endpoint)
        address_endpoint.destroy
        expect(route.reload.mode).to eq "Reject"
        expect(route.endpoint).to be_nil
      end

      it "refuses to be destroyed while a return path route points at it" do
        route = build(:route, server: server, domain: nil, name: "__returnpath__", mode: "Endpoint", endpoint: address_endpoint)
        route.save(validate: false)
        expect(address_endpoint.destroy).to be false
        expect(address_endpoint.reload).to be_persisted
        expect(address_endpoint.errors[:base]).to include("This endpoint is used by the return path route and cannot be deleted")
      end
    end
  end

  describe "return path validation" do
    let(:server) { create(:server) }

    it "requires the return path route to point at an HTTP endpoint" do
      route = build(:route, server: server, domain: nil, name: "__returnpath__", mode: "Endpoint", endpoint: create(:smtp_endpoint, server: server))
      expect(route).not_to be_valid
      expect(route.errors[:base]).to include("Return path routes must point to an HTTP endpoint")
    end

    it "accepts a return path route pointing at an HTTP endpoint" do
      route = build(:route, server: server, domain: nil, name: "__returnpath__", mode: "Endpoint", endpoint: create(:http_endpoint, server: server))
      expect(route).to be_valid
    end

    it "does not stop the whole server from being destroyed" do
      endpoint = create(:http_endpoint, server: server)
      create(:route, server: server, domain: nil, name: "__returnpath__", mode: "Endpoint", endpoint: endpoint)
      expect { server.destroy! }.not_to raise_error
      expect(HTTPEndpoint.exists?(endpoint.id)).to be false
    end
  end
end
