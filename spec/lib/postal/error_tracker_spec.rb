# frozen_string_literal: true

require "rails_helper"

RSpec.describe Postal::ErrorTracker do
  def start_sentry(traces_sample_rate: 0.0)
    allow(Postal::Config.sentry).to receive(:traces_sample_rate).and_return(traces_sample_rate)
    Sentry.init do |config|
      described_class.configure(config)
      config.dsn = "http://12345:67890@sentry.localdomain/sentry/42"
      config.transport.transport_class = Sentry::DummyTransport
      config.background_worker_threads = 0
    end
  end

  def transport
    Sentry.get_current_client.transport
  end

  def sent_logs
    Sentry.get_current_client.flush
    transport.envelopes.flat_map(&:items).select { |item| item.type == "log" }.flat_map { |item| item.payload[:items] }
  end

  describe ".enabled?" do
    it "is off without a DSN" do
      allow(Postal::Config.sentry).to receive(:dsn).and_return(nil)
      allow(Postal::Config.logging).to receive(:sentry_dsn).and_return(nil)
      expect(described_class.enabled?).to be false
    end

    it "is on with a DSN" do
      allow(Postal::Config.rails).to receive(:environment).and_return("production")
      allow(Postal::Config.sentry).to receive(:dsn).and_return(" https://key@sentry.example.com/4 ")
      expect(described_class.enabled?).to be true
      expect(described_class.dsn).to eq "https://key@sentry.example.com/4"
    end

    it "falls back to the legacy logging DSN" do
      allow(Postal::Config.sentry).to receive(:dsn).and_return(nil)
      allow(Postal::Config.logging).to receive(:sentry_dsn).and_return("https://key@sentry.example.com/4")
      expect(described_class.dsn).to eq "https://key@sentry.example.com/4"
    end

    it "is off in the test environment whatever the DSN" do
      allow(Postal::Config.sentry).to receive(:dsn).and_return("https://key@sentry.example.com/4")
      expect(described_class.enabled?).to be false
    end
  end

  describe ".init" do
    it "does nothing without a DSN" do
      allow(Postal::Config.sentry).to receive(:dsn).and_return(nil)
      allow(Postal::Config.logging).to receive(:sentry_dsn).and_return(nil)
      expect(Sentry).not_to receive(:init)
      expect(Postal.logger).not_to receive(:add_destination)
      described_class.init
    end

    it "initialises the SDK and hooks the logger with a DSN" do
      allow(Postal::Config.rails).to receive(:environment).and_return("production")
      allow(Postal::Config.sentry).to receive(:dsn).and_return("https://key@sentry.example.com/4")
      expect(Sentry).to receive(:init)
      expect(Postal.logger).to receive(:add_destination)
      described_class.init
    end
  end

  describe ".configure" do
    subject(:config) { Sentry::Configuration.new.tap { |c| described_class.configure(c) } }

    before do
      allow(Postal::Config.sentry).to receive(:dsn).and_return("https://key@sentry.example.com/4")
    end

    it "keeps personal data, bodies and trace headers out" do
      expect(config.send_default_pii).to be false
      expect(config.data_collection.http_bodies).to eq []
      expect(config.data_collection.cookies.mode).to eq :off
      expect(config.propagate_traces).to be false
    end

    it "uses short timeouts and batches logs" do
      expect(config.transport.open_timeout).to eq 1
      expect(config.transport.timeout).to eq 2
      expect(config.max_log_events).to eq 50
    end

    it "samples every error and a fixed share of traces whatever the caller asks" do
      allow(Postal::Config.sentry).to receive(:traces_sample_rate).and_return(0.01)
      expect(config.sample_rate).to eq 1.0
      expect(config.traces_sampler.call(parent_sampled: true)).to eq 0.01
    end

    it "sets the release, environment and server name" do
      expect(config.release).to start_with "postal@"
      expect(config.environment).to eq Postal::Config.rails.environment
      expect(config.server_name).to eq Socket.gethostname
    end
  end

  describe ".release" do
    before { described_class.instance_variable_set(:@release, nil) }
    after { described_class.instance_variable_set(:@release, nil) }

    it "turns the git describe suffix into build metadata" do
      allow(Postal).to receive(:version).and_return("3.4.2-riadvice-32-gdbbab302")
      expect(described_class.release).to eq "postal@3.4.2-riadvice+32.gdbbab302"
    end

    it "keeps a plain tag" do
      allow(Postal).to receive(:version).and_return("3.4.2-riadvice")
      expect(described_class.release).to eq "postal@3.4.2-riadvice"
    end

    it "uses the commit when there is no version" do
      allow(Postal).to receive(:version).and_return("0.0.0")
      allow(IO).to receive(:popen).and_return("dbbab3021234\n")
      expect(described_class.release).to eq "postal@dbbab3021234"
    end
  end

  describe ".scrub_text" do
    it "masks secret name=value pairs" do
      text = "/api/create?meetingID=42&attendeePW=ap&checksum=ab12&password=x&api_key=k&page=2"
      expect(described_class.scrub_text(text)).to eq "/api/create?meetingID=42&attendeePW=[Filtered]&checksum=[Filtered]" \
                                                     "&password=[Filtered]&api_key=[Filtered]&page=2"
    end

    it "masks credential keys" do
      expect(described_class.scrub_text("key=abc private_key=def monkey=ok")).to eq "key=[Filtered] private_key=[Filtered] monkey=ok"
    end

    it "masks e-mail addresses and IP addresses" do
      text = "Sending to jane.doe@example.com from 192.168.1.20 and 2001:db8::1 via ::1."
      expect(described_class.scrub_text(text)).to eq "Sending to [Filtered] from [Filtered] and [Filtered] via [Filtered]."
    end

    it "leaves times, class names and releases alone" do
      text = "Postal::MessageDB at 12:34:56 on postal@3.4.2-riadvice+5.gabc1234 version 1.2.3"
      expect(described_class.scrub_text(text)).to eq text
    end
  end

  describe ".scrub_data" do
    it "masks secret keys and scrubs strings at any depth" do
      data = { "X-Server-API-Key" => "abc", "nested" => { "password" => 1, "list" => ["to bob@example.com", 3] }, "count" => 2 }
      expect(described_class.scrub_data(data)).to eq({
        "X-Server-API-Key" => "[Filtered]",
        "nested" => { "password" => "[Filtered]", "list" => ["to [Filtered]", 3] },
        "count" => 2
      })
    end
  end

  describe ".scrub_span_description" do
    it "replaces SQL values with placeholders" do
      sql = "SELECT * FROM `postal-server-12`.`messages` WHERE id = 12 AND token = 'ab\\'c' AND rcpt = \"x@y.com\" LIMIT 1"
      expect(described_class.scrub_span_description("db.sql.query", sql))
        .to eq "SELECT * FROM `postal-server-12`.`messages` WHERE id = ? AND token = ? AND rcpt = ? LIMIT ?"
    end

    it "drops the path of outgoing HTTP calls" do
      expect(described_class.scrub_span_description("http.client", "POST https://hooks.example.com/secret/path"))
        .to eq "POST https://hooks.example.com"
    end
  end

  describe ".scrub_log" do
    it "masks the body and attributes and adds the service" do
      log = Sentry::LogEvent.new(level: :error, body: "Failed for bob@example.com",
                                 attributes: { "token" => "abc", "server" => "mx 10.0.0.1", "sentry.release" => "postal@1.0.0", "count" => 3 })
      described_class.scrub_log(log)
      expect(log.body).to eq "Failed for [Filtered]"
      expect(log.attributes).to include("token" => "[Filtered]", "server" => "mx [Filtered]", "sentry.release" => "postal@1.0.0",
                                        "count" => 3, "service.name" => "postal", "host.name" => Socket.gethostname)
    end
  end

  context "with the SDK running" do
    before { start_sentry }
    after { Sentry.close if Sentry.initialized? }

    let(:logger) { Klogger.new(nil, destination: "/dev/null") }

    before { logger.add_destination(described_class.method(:forward_log)) }

    it "scrubs errors before sending them" do
      env = Rack::MockRequest.env_for("https://postal.example.com/messages/12?token=abc&page=2",
                                      "HTTP_X_SERVER_API_KEY" => "secret", "HTTP_COOKIE" => "session=1")
      Sentry.with_scope do |scope|
        scope.set_rack_env(env)
        described_class.capture_exception(RuntimeError.new("Could not send to bob@example.com"), tags: { server_id: 4 })
      end

      event = transport.events.last
      expect(event.exception.values.first.value).to eq "Could not send to [Filtered] (RuntimeError)"
      expect(event.tags).to include(server_id: "4")
      expect(event.request.url).to eq "https://postal.example.com/messages/12"
      expect(event.request.headers["Cookie"]).to eq "[Filtered]"
      expect(event.request.headers["X-Server-Api-Key"]).to eq "[Filtered]"
      expect(event.user).to eq({})
    end

    it "ignores debug records" do
      logger.debug "noise"
      expect(transport.events).to be_empty
      expect(Sentry.get_current_scope.breadcrumbs.members).to be_empty
    end

    it "keeps info and warn records as breadcrumbs" do
      logger.warn "Authentication failure for 10.0.0.1", component: "smtp-server"
      expect(transport.events).to be_empty
      breadcrumb = Sentry.get_current_scope.breadcrumbs.members.last
      expect(breadcrumb.message).to eq "Authentication failure for 10.0.0.1"
      expect(breadcrumb.level).to eq "warning"
      expect(breadcrumb.category).to eq "smtp-server"
    end

    it "turns error records into an issue and a log entry" do
      logger.info "before"
      logger.error "Something broke", component: "worker"
      event = transport.events.last
      expect(event.message).to eq "Something broke"
      expect(event.level).to eq :error
      expect(event.breadcrumbs.members.map(&:message)).to eq ["before"]
      expect(sent_logs.map { |log| log[:body] }).to eq ["Something broke"]
    end

    it "does not forward silenced records" do
      described_class.silence { logger.error "already reported" }
      expect(transport.events).to be_empty
    end

    it "reports an exception once however many lines are logged" do
      error = RuntimeError.new("boom")
      error.set_backtrace(["a.rb:1", "b.rb:2"])
      test_logger = TestLogger.new
      described_class.report(error, logger: test_logger, message: "Error talking to spamd")
      expect(test_logger).to have_logged("Error talking to spamd")
      expect(test_logger).to have_logged("RuntimeError (boom)")
      expect(test_logger).to have_logged("b.rb:2")
      expect(transport.events.size).to eq 1
      expect(sent_logs.map { |log| log[:body] }).to eq ["Error talking to spamd: RuntimeError (boom)"]
    end

    it "identifies users by id and role only" do
      described_class.identify(build(:user, id: 17, admin: true))
      described_class.capture_exception(RuntimeError.new("boom"))
      event = transport.events.last
      expect(event.user).to eq({ id: "17" })
      expect(event.tags).to include("user.role" => "admin")
    end

    it "runs traced work without a span when not sampled" do
      result = described_class.transaction("Job", operation: "task") do
        described_class.trace("db.sql.query", "SELECT 1") { :done }
      end
      expect(result).to eq :done
      expect(transport.events).to be_empty
    end
  end

  context "with every trace sampled" do
    before { start_sentry(traces_sample_rate: 1.0) }
    after { Sentry.close if Sentry.initialized? }

    it "records scrubbed spans in the transaction" do
      described_class.transaction("MessageDequeuer", operation: "queue.process", tags: { server_id: 3 }) do
        described_class.trace("db.sql.query", "SELECT * FROM messages WHERE id = 5", "db.system" => "mysql") { true }
      end

      transaction = transport.events.last
      expect(transaction.transaction).to eq "MessageDequeuer"
      expect(transaction.contexts[:trace]).to include(op: "queue.process", status: "ok")
      expect(transaction.tags).to include(server_id: "3")
      span = transaction.spans.find { |s| s[:op] == "db.sql.query" }
      expect(span).to include(description: "SELECT * FROM messages WHERE id = ?", status: "ok")
      expect(span[:data]).to include("db.system" => "mysql")
    end

    it "marks the span as failed and re-raises" do
      expect do
        described_class.transaction("Job", operation: "task") do
          described_class.trace("smtp.client", "SMTP send") { raise ArgumentError, "bad" }
        end
      end.to raise_error(ArgumentError)

      transaction = transport.events.last
      expect(transaction.contexts[:trace][:status]).to eq "internal_error"
      expect(transaction.spans.find { |s| s[:op] == "smtp.client" }[:status]).to eq "internal_error"
    end
  end
end
