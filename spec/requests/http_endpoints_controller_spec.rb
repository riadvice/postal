# frozen_string_literal: true

require "rails_helper"

RSpec.describe "HTTPEndpointsController", type: :request do
  let(:user) { create(:user, admin: true) }
  let(:organization) { create(:organization, owner: user) }
  let(:server) { create(:server, organization: organization) }
  let(:endpoint) { create(:http_endpoint, server: server) }

  before do
    post "/login", params: { email_address: user.email_address, password: "passw0rd" }
  end

  describe "DELETE /org/:org/servers/:server/http_endpoints/:id" do
    context "when nothing depends on the endpoint" do
      it "deletes it and redirects to the list" do
        delete "/org/#{organization.permalink}/servers/#{server.permalink}/http_endpoints/#{endpoint.uuid}", as: :json
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["redirect_to"]).to end_with("/http_endpoints")
        expect(HTTPEndpoint.exists?(endpoint.id)).to be false
        expect(flash[:alert]).to be_nil
      end
    end

    context "when the return path route points at the endpoint" do
      before do
        create(:route, server: server, domain: nil, name: "__returnpath__", mode: "Endpoint", endpoint: endpoint)
      end

      it "keeps the endpoint and explains why" do
        delete "/org/#{organization.permalink}/servers/#{server.permalink}/http_endpoints/#{endpoint.uuid}", as: :json
        expect(response).to have_http_status(:ok)
        expect(HTTPEndpoint.exists?(endpoint.id)).to be true
        expect(flash[:alert]).to eq "This endpoint is used by the return path route and cannot be deleted"
      end
    end
  end
end
