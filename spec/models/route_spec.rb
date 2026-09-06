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
  end
end
