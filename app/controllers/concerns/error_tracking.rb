# frozen_string_literal: true

module ErrorTracking

  extend ActiveSupport::Concern

  included do
    class_attribute :error_tracking_area, default: "web"
    before_action :tag_error_tracking_scope
  end

  private

  def tag_error_tracking_scope
    user = current_user if error_tracking_area == "web" && logged_in?
    Postal::ErrorTracker.tag_request(request, area: error_tracking_area, user: user)
  end

end
