# frozen_string_literal: true

# == Schema Information
#
# Table name: address_endpoints
#
#  id           :integer          not null, primary key
#  server_id    :integer
#  uuid         :string(255)
#  address      :string(255)
#  last_used_at :datetime
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#

class AddressEndpoint < ApplicationRecord

  include HasUUID
  include HasRoutes

  belongs_to :server

  validates :address, presence: true, format: { with: /@/ }, uniqueness: { scope: [:server_id], message: "has already been added", case_sensitive: false }

  def mark_as_used
    update_column(:last_used_at, Time.now)
  end

  def description
    address
  end

  def domain
    address.split("@", 2).last
  end

end
