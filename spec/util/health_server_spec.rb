# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthServer do
  subject(:app) { described_class.new(name: "test-process") }

  def call(path)
    app.call("PATH_INFO" => path)
  end

  describe "#call" do
    it "responds to /health" do
      expect(call("/health")).to eq [200, { "Content-Type" => "text/plain" }, ["OK"]]
    end

    it "responds to /metrics with prometheus text output" do
      status, headers, body = call("/metrics")
      expect(status).to eq 200
      expect(headers).to eq("Content-Type" => "text/plain")
      expect(body.first).to be_a String
    end

    it "responds to / with the process description" do
      status, _, body = call("/")
      expect(status).to eq 200
      expect(body.first).to match(/\Atest-process \(pid: \d+, host: .+\)\z/)
    end

    ["/health/", "/HEALTH", "/healthz", "//health", "/health\n", "/../health", "/metrics/../health",
     "/health?x=1", "/health/../metrics", "/health%00", "", "/unknown", "health",].each do |path|
      it "returns 404 for #{path.inspect}" do
        expect(call(path)).to eq [404, { "Content-Type" => "text/plain" }, ["Not Found"]]
      end
    end

    it "returns 404 when there is no path" do
      expect(call(nil)).to eq [404, { "Content-Type" => "text/plain" }, ["Not Found"]]
    end
  end

  describe HealthServer::LoggerProxy do
    subject(:proxy) { described_class.new }

    before do
      allow(Postal.logger).to receive(:info)
      allow(Postal.logger).to receive(:debug)
    end

    describe "severity predicates" do
      it "reports debug as disabled" do
        expect(proxy.debug?).to be false
      end

      it "reports the other severities as enabled" do
        expect(proxy.info?).to be true
        expect(proxy.warn?).to be true
        expect(proxy.error?).to be true
        expect(proxy.fatal?).to be true
      end
    end

    describe "#add" do
      it "ignores debug messages entirely" do
        proxy.add(:debug, "WEBrick::HTTPServer#start: pid=1 port=9090")
        expect(Postal.logger).not_to have_received(:info)
        expect(Postal.logger).not_to have_received(:debug)
      end

      it "logs the port when the server starts" do
        proxy.add(:info, "WEBrick::HTTPServer#start: pid=1234 port=9090")
        expect(Postal.logger).to have_received(:info).with("started health server on port 9090", component: "health-server")
      end

      it "captures the last run of digits after port=" do
        proxy.add(:info, "WEBrick::HTTPServer#start: port=9090 pid=1")
        expect(Postal.logger).to have_received(:info).with("started health server on port 9090", component: "health-server")
      end

      it "falls through to debug when the port is not numeric" do
        proxy.add(:info, "WEBrick::HTTPServer#start: pid=1 port=abc")
        expect(Postal.logger).not_to have_received(:info)
        expect(Postal.logger).to have_received(:debug).with("WEBrick::HTTPServer#start: pid=1 port=abc", component: "health-server")
      end

      it "logs when the server stops" do
        proxy.add(:info, "WEBrick::HTTPServer#start done.")
        expect(Postal.logger).to have_received(:info).with("stopped health server", component: "health-server")
      end

      ["WEBrick 1.8.1", "ruby 3.3.0 (2024-01-01) [x86_64-linux]", "Rackup::Handler::WEBrick is mounted on /.",
       "close TCPSocket(127.0.0.1, 9090)", "going to shutdown ...",].each do |message|
        it "silences #{message.inspect}" do
          proxy.add(:info, message)
          expect(Postal.logger).not_to have_received(:info)
          expect(Postal.logger).not_to have_received(:debug)
        end
      end

      it "does not silence routine messages which are not at the start of the line" do
        proxy.add(:info, "  WEBrick 1.8.1")
        expect(Postal.logger).to have_received(:debug).with("  WEBrick 1.8.1", component: "health-server")
      end

      it "does not silence a WEBrick line without a version number" do
        proxy.add(:info, "WEBrick started")
        expect(Postal.logger).to have_received(:debug).with("WEBrick started", component: "health-server")
      end

      it "does not silence a ruby line without a version number" do
        proxy.add(:info, "ruby is great")
        expect(Postal.logger).to have_received(:debug).with("ruby is great", component: "health-server")
      end

      it "logs anything else at debug level" do
        proxy.add(:warn, "something unexpected")
        expect(Postal.logger).to have_received(:debug).with("something unexpected", component: "health-server")
      end

      it "logs a message which is not a string at debug level" do
        proxy.add(:error, 123)
        expect(Postal.logger).to have_received(:debug).with(123, component: "health-server")
      end
    end

    describe "severity methods" do
      it "delegates to #add" do
        proxy.info("WEBrick::HTTPServer#start done.")
        expect(Postal.logger).to have_received(:info).with("stopped health server", component: "health-server")
      end

      it "drops debug messages" do
        proxy.debug("WEBrick::HTTPServer#start done.")
        expect(Postal.logger).not_to have_received(:info)
      end
    end
  end
end
