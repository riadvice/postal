# frozen_string_literal: true

require "rails_helper"

RSpec.describe Route do
  describe "name validation" do
    subject(:route) { build(:route, server: server, domain: domain) }

    let(:server) { create(:server) }
    let(:domain) { create(:domain, owner: server) }

    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to allow_value("test").for(:name) }
    it { is_expected.to allow_value("hello.world").for(:name) }
    it { is_expected.to allow_value("first-last").for(:name) }
    it { is_expected.to allow_value("123").for(:name) }
    it { is_expected.to allow_value("a.b-c.d").for(:name) }
    it { is_expected.to allow_value("*").for(:name) }
    it { is_expected.to allow_value("__returnpath__").for(:name) }
    it { is_expected.to_not allow_value("TEST").for(:name) }
    it { is_expected.to_not allow_value("Test").for(:name) }
    it { is_expected.to_not allow_value("hello world").for(:name) }
    it { is_expected.to_not allow_value(" test").for(:name) }
    it { is_expected.to_not allow_value("test ").for(:name) }
    it { is_expected.to_not allow_value("test\n").for(:name) }
    it { is_expected.to_not allow_value("test\nevil").for(:name) }
    it { is_expected.to_not allow_value("hello+tag").for(:name) }
    it { is_expected.to_not allow_value("hello_world").for(:name) }
    it { is_expected.to_not allow_value("üser").for(:name) }
    it { is_expected.to_not allow_value("user@example.com").for(:name) }
    it { is_expected.to_not allow_value("test/").for(:name) }
    it { is_expected.to_not allow_value("te%st").for(:name) }
    it { is_expected.to_not allow_value("\"quoted\"").for(:name) }
    it { is_expected.to_not allow_value("*test").for(:name) }
    it { is_expected.to_not allow_value("test*").for(:name) }
    it { is_expected.to_not allow_value("**").for(:name) }
    it { is_expected.to_not allow_value("*.*").for(:name) }
    it { is_expected.to_not allow_value("__RETURNPATH__").for(:name) }
    it { is_expected.to_not allow_value("_returnpath_").for(:name) }
    it { is_expected.to_not allow_value("__returnpath__x").for(:name) }
    it { is_expected.to_not allow_value("x__returnpath__").for(:name) }
    it { is_expected.to_not allow_value("__returnpath__\n").for(:name) }
    it { is_expected.to_not allow_value("").for(:name) }
    it { is_expected.to_not allow_value("   ").for(:name) }

    it "rejects a leading dot" do
      pending "the name format only restricts the character set"
      expect(route).not_to allow_value(".test").for(:name)
    end

    it "rejects consecutive dots" do
      pending "the name format only restricts the character set"
      expect(route).not_to allow_value("a..b").for(:name)
    end
  end

  describe "#_endpoint=" do
    subject(:route) { build(:route, server: server, domain: domain) }

    let(:server) { create(:server) }
    let(:domain) { create(:domain, owner: server) }
    let(:http_endpoint) { create(:http_endpoint, server: server) }
    let(:smtp_endpoint) { create(:smtp_endpoint, server: server) }
    let(:address_endpoint) { create(:address_endpoint, server: server) }

    it "clears the endpoint and mode when blank" do
      route._endpoint = ""
      expect(route.endpoint).to be_nil
      expect(route.mode).to be_nil
      route._endpoint = nil
      expect(route.mode).to be_nil
    end

    it "sets the mode when given a mode name" do
      route._endpoint = "Reject"
      expect(route.endpoint).to be_nil
      expect(route.mode).to eq "Reject"
    end

    it "finds an HTTP endpoint" do
      route._endpoint = "HTTPEndpoint##{http_endpoint.uuid}"
      expect(route.endpoint).to eq http_endpoint
      expect(route.mode).to eq "Endpoint"
    end

    it "finds an SMTP endpoint" do
      route._endpoint = "SMTPEndpoint##{smtp_endpoint.uuid}"
      expect(route.endpoint).to eq smtp_endpoint
    end

    it "finds an address endpoint" do
      route._endpoint = "AddressEndpoint##{address_endpoint.uuid}"
      expect(route.endpoint).to eq address_endpoint
    end

    it "sets a nil endpoint when the UUID is unknown" do
      route._endpoint = "HTTPEndpoint#unknown"
      expect(route.endpoint).to be_nil
      expect(route.mode).to eq "Endpoint"
    end

    it "sets a nil endpoint when the UUID is empty" do
      route._endpoint = "HTTPEndpoint#"
      expect(route.endpoint).to be_nil
    end

    it "treats everything after the first hash as the UUID" do
      route._endpoint = "HTTPEndpoint##{http_endpoint.uuid}#extra"
      expect(route.endpoint).to be_nil
    end

    it "rejects a class which is not an endpoint" do
      expect { route._endpoint = "Server##{server.uuid}" }.to raise_error(Postal::Error, "Invalid endpoint class name 'Server'")
    end

    it "rejects a class name with different casing" do
      expect { route._endpoint = "httpendpoint##{http_endpoint.uuid}" }.to raise_error(Postal::Error, /Invalid endpoint class name/)
    end

    it "rejects an empty class name" do
      expect { route._endpoint = "#abc" }.to raise_error(Postal::Error, "Invalid endpoint class name ''")
    end

    it "rejects a class name with surrounding whitespace" do
      expect { route._endpoint = " HTTPEndpoint##{http_endpoint.uuid}" }.to raise_error(Postal::Error, /Invalid endpoint class name/)
    end

    it "does not constantize arbitrary class names" do
      expect { route._endpoint = "Kernel#exit" }.to raise_error(Postal::Error, "Invalid endpoint class name 'Kernel'")
    end
  end

  describe "#_endpoint" do
    let(:server) { create(:server) }
    let(:http_endpoint) { create(:http_endpoint, server: server) }

    it "returns the class and UUID for an endpoint route" do
      route = build(:route, server: server, mode: "Endpoint", endpoint: http_endpoint)
      expect(route._endpoint).to eq "HTTPEndpoint##{http_endpoint.uuid}"
    end

    it "returns the mode for other routes" do
      expect(build(:route, server: server, mode: "Hold")._endpoint).to eq "Hold"
    end
  end

  describe "#wildcard?" do
    it "is true for the wildcard name only" do
      expect(build(:route, name: "*").wildcard?).to be true
      expect(build(:route, name: "test").wildcard?).to be false
      expect(build(:route, name: "**").wildcard?).to be false
    end
  end

  describe "#return_path?" do
    it "is true for the return path name only" do
      expect(build(:route, name: "__returnpath__").return_path?).to be true
      expect(build(:route, name: "__RETURNPATH__").return_path?).to be false
      expect(build(:route, name: "returnpath").return_path?).to be false
    end
  end

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
