# frozen_string_literal: true

class MessagesController < ApplicationController

  include WithinOrganization

  before_action { @server = organization.servers.present.find_by_permalink!(params[:server_id]) }
  before_action { params[:id] && @message = @server.message_db.message(params[:id].to_i) }

  def new
    if params[:direction] == "incoming"
      @message = IncomingMessagePrototype.new(@server, request.ip, "web-ui", {})
      @message.from = session[:test_in_from] || current_user.email_tag
      @message.to = @server.routes.order(:name).first&.description
    else
      @message = OutgoingMessagePrototype.new(@server, request.ip, "web-ui", {})
      @message.to = session[:test_out_to] || current_user.email_address
      if domain = @server.domains.verified.order(:name).first
        @message.from = "test@#{domain.name}"
      end
    end
    @message.subject = "Test Message at #{Time.zone.now.to_fs(:long)}"
    @message.plain_body = "This is a message to test the delivery of messages through Postal."
  end

  def create
    if params[:direction] == "incoming"
      session[:test_in_from] = params[:message][:from] if params[:message]
      @message = IncomingMessagePrototype.new(@server, request.ip, "web-ui", params[:message])
      @message.attachments = [{ name: "test.txt", content_type: "text/plain", data: "Hello world!" }]
    else
      session[:test_out_to] = params[:message][:to] if params[:message]
      @message = OutgoingMessagePrototype.new(@server, request.ip, "web-ui", params[:message])
    end
    if result = @message.create_messages
      if result.size == 1
        redirect_to_with_json organization_server_message_path(organization, @server, result.first.last[:id]), notice: "Message was queued successfully"
      else
        redirect_to_with_json [:queue, organization, @server], notice: "Messages queued successfully "
      end
    else
      respond_to do |wants|
        wants.html do
          flash.now[:alert] = "Your message could not be sent. Ensure that all fields are completed fully. #{result.errors.inspect}"
          render "new"
        end
        wants.json do
          render json: { flash: { alert: "Your message could not be sent. Please check all field are completed fully." } }
        end
      end

    end
  end

  def outgoing
    @searchable = true
    get_messages("outgoing")
    respond_to do |wants|
      wants.html
      wants.json do
        render json: {
          flash: flash.each_with_object({}) { |(type, message), hash| hash[type] = message },
          region_html: render_to_string(partial: "index", formats: [:html])
        }
      end
    end
  end

  def incoming
    @searchable = true
    get_messages("incoming")
    respond_to do |wants|
      wants.html
      wants.json do
        render json: {
          flash: flash.each_with_object({}) { |(type, message), hash| hash[type] = message },
          region_html: render_to_string(partial: "index", formats: [:html])
        }
      end
    end
  end

  def held
    get_messages("held")
  end

  def filter_values
    case params[:field]
    when "tag"
      values = @server.message_db.select(:messages, fields: [:tag], group: :tag, order: :tag, limit: 20).filter_map { |r| r["tag"] }
    when "status"
      values = %w[Pending Sent Held SoftFail HardFail Bounced Error Processed]
    when "spam", "held", "threat"
      values = %w[Yes No]
    else
      values = []
    end
    render json: { values: values }
  end

  def deliveries
    render json: { html: render_to_string(partial: "deliveries", locals: { message: @message }) }
  end

  def html_raw
    override_content_security_policy_directives(
      default_src: %w('none'),
      script_src: %w('none'),
      style_src: %w('unsafe-inline'),
      img_src: %w(* data:),
      font_src: %w(*),
      frame_ancestors: %w('self'),
      form_action: %w('none'),
      base_uri: %w('none')
    )
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Referrer-Policy"] = "no-referrer"
    render html: @message.html_body_without_tracking_image.html_safe
  end

  def spam_checks
    @spam_checks = @message.spam_checks.sort_by { |s| s["score"] }.reverse
  end

  def attachment
    if @message.attachments.size > params[:attachment].to_i
      attachment = @message.attachments[params[:attachment].to_i]
      send_data attachment.body, content_type: attachment.mime_type, disposition: "download", filename: attachment.filename
    else
      redirect_to attachments_organization_server_message_path(organization, @server, @message.id), alert: "Attachment not found. Choose an attachment from the list below."
    end
  end

  def download
    if @message.raw_message
      send_data @message.raw_message, filename: "Message-#{organization.permalink}-#{@server.permalink}-#{@message.id}.eml", content_type: "text/plain"
    else
      redirect_to organization_server_message_path(organization, @server, @message.id), alert: "We no longer have the raw message stored for this message."
    end
  end

  def retry
    if @message.raw_message?
      if @message.queued_message
        @message.queued_message.retry_now
        flash[:notice] = "This message will be retried shortly."
      elsif @message.held?
        @message.add_to_message_queue(manual: true)
        flash[:notice] = "This message has been released. Delivery will be attempted shortly."
      else
        @message.add_to_message_queue(manual: true)
        flash[:notice] = "This message will be redelivered shortly."
      end
    else
      flash[:alert] = "This message is no longer available."
    end
    redirect_to_with_json organization_server_message_path(organization, @server, @message.id)
  end

  def cancel_hold
    @message.cancel_hold
    redirect_to_with_json organization_server_message_path(organization, @server, @message.id)
  end

  def remove_from_queue
    if @message.queued_message && !@message.queued_message.locked?
      @message.queued_message.destroy
    end
    redirect_to_with_json organization_server_message_path(organization, @server, @message.id)
  end

  def suppressions
    @suppressions = @server.message_db.suppression_list.all_with_pagination(params[:page])
  end

  def activity
    @entries = @message.activity_entries
  end

  private

  def get_messages(scope)
    if scope == "held"
      options = { where: { held: true } }
    else
      options = { where: { scope: scope, spam: false }, order: :timestamp, direction: "desc" }

      if @query = (params[:query] || session["msg_query_#{@server.id}_#{scope}"]).presence
        session["msg_query_#{@server.id}_#{scope}"] = @query
        qs = QueryString.new(@query)
        if qs.empty?
          flash.now[:alert] = "It doesn't appear you entered anything to filter on. Please double check your query."
        else
          @queried = true
          @parsed_filters = qs.hash.slice(*(QueryString::RECOGNIZED_KEYS - %w[order]))

          if qs.unrecognized_keys.any?
            flash.now[:alert] = "Unrecognized filter#{'s' if qs.unrecognized_keys.size > 1}: #{qs.unrecognized_keys.join(', ')}. They have been ignored."
          end

          if qs[:order] == "oldest-first"
            options[:direction] = "asc"
          end

          options[:where][:rcpt_to] = text_match_value(qs[:to]) if qs[:to]
          options[:where][:mail_from] = text_match_value(qs[:from]) if qs[:from]
          options[:where][:subject] = text_match_value(qs[:subject]) if qs[:subject]
          options[:where][:status] = qs[:status] if qs[:status]
          options[:where][:token] = qs[:token] if qs[:token]

          if qs[:msgid]
            options[:where][:message_id] = qs[:msgid]
            options[:where].delete(:spam)
            options[:where].delete(:scope)
          end
          options[:where][:tag] = qs[:tag] if qs[:tag]
          options[:where][:id] = qs[:id] if qs[:id]
          options[:where][:spam] = true if qs[:spam] == "yes" || qs[:spam] == "y"
          options[:where][:held] = boolean_value?(qs[:held]) unless qs[:held].nil?
          options[:where][:threat] = boolean_value?(qs[:threat]) unless qs[:threat].nil?
          if qs[:before] || qs[:after]
            options[:where][:timestamp] = {}
            if qs[:before]
              begin
                options[:where][:timestamp][:less_than] = get_time_from_string(qs[:before]).to_f
              rescue TimeUndetermined
                flash.now[:alert] = "Couldn't determine time for before from '#{qs[:before]}'"
              end
            end

            if qs[:after]
              begin
                options[:where][:timestamp][:greater_than] = get_time_from_string(qs[:after]).to_f
              rescue TimeUndetermined
                flash.now[:alert] = "Couldn't determine time for after from '#{qs[:after]}'"
              end
            end
          end
        end
      else
        session["msg_query_#{@server.id}_#{scope}"] = nil
      end
    end

    @messages = @server.message_db.messages_with_pagination(params[:page], options)
  end

  # Text fields (to/from/subject) accept an optional wildcard convention so the
  # filter builder can offer "contains"/"starts with" without a new DSL:
  #   *foo*  => contains "foo"
  #   foo*   => starts with "foo"
  #   foo    => exact match (default, keeps using the existing indexes)
  def text_match_value(value)
    return value unless value.is_a?(String)

    if value.start_with?("*") && value.end_with?("*") && value.length > 1
      { contains: value[1..-2] }
    elsif value.end_with?("*") && value.length > 1
      { starts_with: value[0..-2] }
    else
      value
    end
  end

  def boolean_value?(value)
    %w[yes y true 1].include?(value.to_s.downcase)
  end

  class TimeUndetermined < Postal::Error; end

  def get_time_from_string(string)
    begin
      if string =~ /\A(\d{4}|\d{2})-(\d{2})-(\d{2})(?: (\d{2}):(\d{2}))?\z/
        year = ::Regexp.last_match(1).to_i
        year += 2000 if ::Regexp.last_match(1).length == 2
        time = Time.new(year, ::Regexp.last_match(2).to_i, ::Regexp.last_match(3).to_i, ::Regexp.last_match(4).to_i, ::Regexp.last_match(5).to_i)
      else
        time = Chronic.parse(string, context: :past)
      end
    rescue StandardError
      time = nil
    end

    raise TimeUndetermined, "Couldn't determine a suitable time from '#{string}'" if time.nil?

    time
  end

end
