# frozen_string_literal: true

# Shared by every endpoint type a route can deliver to
module HasRoutes

  extend ActiveSupport::Concern

  included do
    has_many :routes, as: :endpoint
    has_many :additional_route_endpoints, dependent: :destroy, as: :endpoint

    before_destroy :update_routes
  end

  def update_routes
    return if destroyed_by_association

    if routes.any?(&:return_path?)
      errors.add(:base, "This endpoint is used by the return path route and cannot be deleted")
      throw :abort
    end

    routes.each { |r| r.update(endpoint: nil, mode: "Reject") }
  end

end
