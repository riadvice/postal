# frozen_string_literal: true

require "rails_helper"

RSpec.describe "AddressEndpointsController", type: :request do
  let(:user) { create(:user, admin: true) }
  let(:organization) { create(:organization, owner: user) }
  let(:server) { create(:server, organization: organization) }
  let(:endpoint) { create(:address_endpoint, server: server) }

  before do
    post "/login", params: { email_address: user.email_address, password: "passw0rd" }
  end

  describe "DELETE /org/:org/servers/:server/address_endpoints/:id" do
    it "deletes the endpoint and redirects to the list" do
      delete "/org/#{organization.permalink}/servers/#{server.permalink}/address_endpoints/#{endpoint.uuid}", as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["redirect_to"]).to end_with("/address_endpoints")
      expect(AddressEndpoint.exists?(endpoint.id)).to be false
      expect(flash[:alert]).to be_nil
    end

    it "keeps the endpoint and explains why when the return path route points at it" do
      route = build(:route, server: server, domain: nil, name: "__returnpath__", mode: "Endpoint", endpoint: endpoint)
      route.save(validate: false)
      delete "/org/#{organization.permalink}/servers/#{server.permalink}/address_endpoints/#{endpoint.uuid}", as: :json
      expect(response).to have_http_status(:ok)
      expect(AddressEndpoint.exists?(endpoint.id)).to be true
      expect(flash[:alert]).to eq "This endpoint is used by the return path route and cannot be deleted"
    end
  end
end
