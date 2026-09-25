# frozen_string_literal: true

require "ipaddr"
require "socket"

module Postal
  # Reports errors, error logs and request timings to a Sentry-compatible service
  # through the Sentry SDK. Nothing is sent unless a DSN is configured.
  module ErrorTracker

    PRODUCT = "postal"
    FILTERED = "[Filtered]"
    LEVELS = [:debug, :info, :warn, :error, :fatal].freeze
    SILENCE_KEY = :postal_error_tracker_silenced

    SECRET_NAME = /pass|secret|token|checksum|api[_-]?key|authori[sz]ation|cookie|pw\z|(?:\A|[_\-.\[])key\]?\z/i
    PAIR = /[\w.\-\[\]]+=[^&\s"'<>]*/
    EMAIL = /[\w.!#$%&'*+\/=?^`{|}~-]+@(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}\b/i
    IPV4 = /(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?!\.?\w)/
    IPV6 = /(?<![\w:.])(?=[0-9a-f:.]*::|(?:[0-9a-f]{1,4}:){7})[0-9a-f:.]+(?<![.:])(?!\w)/i
    PERSONAL_DATA = Regexp.union(EMAIL, IPV4, IPV6)
    SQL_TOKEN = /(`(?:[^`]|``)*+`)|'(?:[^'\\]++|\\.|'')*+'|"(?:[^"\\]++|\\.|"")*+"|\b0x\h+\b|(?<![\w$])-?\d+(?:\.\d+)?(?:e[+-]?\d+)?\b/im
    URL_PATH = /\b(https?:\/\/[^\/\s?#]+)\S*/i

    class << self

      def enabled?
        dsn.present? && Config.rails.environment != "test"
      end

      def dsn
        (Config.sentry.dsn.presence || Config.logging.sentry_dsn).to_s.strip
      end

      def init
        return unless enabled?

        Sentry.init { |config| configure(config) }
        Sentry.set_tags(area: "cli")
        Postal.logger.add_destination(method(:forward_log))
      end

      def configure(config)
        config.dsn = dsn
        config.environment = Config.rails.environment.presence || "production"
        config.release = release
        config.traces_sampler = -> (_context) { Config.sentry.traces_sample_rate.to_f }
        config.send_default_pii = false
        config.data_collection.http_bodies = []
        config.propagate_traces = false
        config.auto_session_tracking = false
        config.send_client_reports = false
        config.max_log_events = 50
        config.transport.open_timeout = 1
        config.transport.timeout = 2
        config.before_send = -> (event, _hint) { scrub(event) }
        config.before_send_transaction = -> (event, _hint) { scrub(event) }
        config.before_send_log = -> (log) { scrub_log(log) }
      end

      def release
        @release ||= "#{PRODUCT}@#{version.sub(/-(\d+)-g(\h+)\z/, '+\1.g\2')}".first(200)
      end

      def area=(area)
        Sentry.set_tags(area: area) if Sentry.initialized?
      end

      # Names the request after its route pattern so its errors and timings
      # group together
      def tag_request(request, area:, user: nil)
        return unless Sentry.initialized?

        scope = Sentry.get_current_scope
        scope.set_tags(area: area, request_id: request.request_id)
        route = request.route_uri_pattern&.delete_suffix("(.:format)")
        scope.set_transaction_name("#{request.request_method} #{route}", source: :route) if route
        identify(user) if user
      end

      def identify(user)
        return unless Sentry.initialized?

        Sentry.set_user(id: user.id.to_s)
        Sentry.set_tags("user.role" => user.admin? ? "admin" : "user")
      end

      def capture_exception(exception, tags: {}, extra: {})
        return unless Sentry.initialized?

        Sentry.capture_exception(exception, tags: tags.compact.transform_values(&:to_s), extra: extra)
      end

      # Logs an exception with its backtrace and reports it once, not once
      # per logged line
      def report(exception, logger:, message: nil, tags: {}, extra: {}, **log_tags)
        summary = "#{exception.class} (#{exception.message})"
        silence do
          [message, summary, *exception.backtrace].compact.each { |line| logger.error(line, **log_tags) }
        end
        return unless Sentry.initialized?

        capture_exception(exception, tags: tags, extra: extra)
        Sentry.logger.error([message, summary].compact.join(": "), **log_tags)
      end

      # Log records written in the block are not forwarded
      def silence
        previous = Thread.current[SILENCE_KEY]
        Thread.current[SILENCE_KEY] = true
        yield
      ensure
        Thread.current[SILENCE_KEY] = previous
      end

      def transaction(name, operation:, tags: {}, &block)
        return yield unless Sentry.initialized?

        Sentry.with_scope do |scope|
          scope.set_tags(tags.compact.transform_values(&:to_s))
          scope.set_transaction_name(name, source: :task)
          transaction = Sentry.start_transaction(name: name, op: operation, source: :task)
          scope.set_span(transaction) if transaction
          run_span(transaction, &block)
        ensure
          transaction&.finish
        end
      end

      # Only creates a span inside a sampled transaction, so unsampled work
      # costs nothing
      def trace(operation, description, **data, &block)
        return yield unless Sentry.initialized? && Sentry.get_current_scope.get_span&.sampled

        Sentry.with_child_span(op: operation, description: scrub_span_description(operation, description), origin: "manual") do |span|
          scrub_span_data(operation, data).each { |key, value| span.set_data(key, value) }
          run_span(span, &block)
        end
      end

      def forward_log(_logger, payload, _group_ids)
        level = LEVELS.index(payload[:severity]&.to_sym)
        return if Thread.current[SILENCE_KEY] || level.nil? || level < level_setting(:breadcrumb_level, :info)

        severity = LEVELS[level]
        message = payload[:message].to_s
        attributes = payload.except(:time, :severity, :message).transform_values { |v| (v in String | Numeric | true | false) ? v : v.to_s }

        if level >= level_setting(:log_level, :error)
          Sentry.capture_message(message, level: severity, extra: { "log.attributes" => attributes })
          Sentry.logger.public_send(severity, message, **attributes.symbolize_keys)
        else
          Sentry.add_breadcrumb(Sentry::Breadcrumb.new(category: (payload[:component] || PRODUCT).to_s,
                                                       level: severity.to_s, message: message, data: attributes))
        end
      end

      def scrub_text(text)
        return text unless text.is_a?(String)

        text.scrub
            .gsub(PAIR) { |pair| secret_name?(pair.split("=").first) ? pair.sub(/=.*/, "=#{FILTERED}") : pair }
            .gsub(PERSONAL_DATA) { |match| match.include?("@") || ip_address?(match) ? FILTERED : match }
      end

      def scrub_data(data)
        data.is_a?(Hash) ? parameter_filter.filter(data) : scrub_text(data)
      end

      def scrub(event)
        if (request = event.request)
          request.url = scrub_text(request.url)
          request.query_string = scrub_text(request.query_string)
          [:headers, :data, :cookies, :env].each { |field| request.public_send("#{field}=", scrub_data(request.public_send(field))) }
        end

        event.message &&= scrub_text(event.message)
        event.extra = scrub_data(event.extra)
        Array(event.try(:exception)&.values).each { |exception| exception.value = scrub_text(exception.value) }
        event.breadcrumbs&.each do |breadcrumb|
          breadcrumb.message = scrub_text(breadcrumb.message)
          breadcrumb.data = scrub_data(breadcrumb.data)
        end
        event.spans = event.spans.map { |span| scrub_span(span) } if event.try(:spans)
        event
      end

      def scrub_log(log)
        log.body = scrub_text(log.body)
        log.attributes = scrub_data(log.attributes).merge("service.name" => PRODUCT, "host.name" => Socket.gethostname)
        log
      end

      def scrub_span_description(operation, description)
        return description unless description.is_a?(String)

        description = description.gsub(SQL_TOKEN) { Regexp.last_match(1) || "?" } if operation.start_with?("db.sql")
        description = strip_url_path(description) if operation.start_with?("http.client")
        scrub_text(description).truncate(2000)
      end

      private

      def version
        return Postal.version unless Postal.version == "0.0.0"

        IO.popen(%w[git rev-parse --short=12 HEAD], err: File::NULL, &:read).strip.presence || Postal.version
      rescue SystemCallError
        Postal.version
      end

      def level_setting(name, default)
        LEVELS.index(Config.sentry.public_send(name).to_s.downcase.to_sym) || LEVELS.index(default)
      end

      def run_span(span)
        result = yield
        span&.set_status("ok")
        result
      rescue Exception # rubocop:disable Lint/RescueException
        span&.set_status("internal_error")
        raise
      end

      def parameter_filter
        @parameter_filter ||= ActiveSupport::ParameterFilter.new(
          [SECRET_NAME, -> (_key, value) { value.replace(scrub_text(value)) if value.is_a?(String) }],
          mask: FILTERED
        )
      end

      def scrub_span(span)
        operation = span[:op].to_s
        span.merge(description: scrub_span_description(operation, span[:description]),
                   data: span[:data] && scrub_span_data(operation, span[:data]))
      end

      def scrub_span_data(operation, data)
        data = scrub_data(data)
        return data unless operation.start_with?("http.client")

        data.transform_values { |v| v.is_a?(String) ? strip_url_path(v) : v }
      end

      # Webhook URLs belong to customers and may carry secrets in their path
      def strip_url_path(text)
        text.gsub(URL_PATH, '\1')
      end

      def secret_name?(name)
        name.to_s.match?(SECRET_NAME)
      end

      def ip_address?(text)
        IPAddr.new(text)
      rescue IPAddr::Error
        false
      end

    end

  end
end
