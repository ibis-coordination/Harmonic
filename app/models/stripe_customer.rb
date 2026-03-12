# typed: true

class StripeCustomer < ApplicationRecord
  extend T::Sig

  belongs_to :billable, polymorphic: true

  validates :stripe_id, presence: true, uniqueness: true
  validates :billable_id, uniqueness: { scope: :billable_type }
end
