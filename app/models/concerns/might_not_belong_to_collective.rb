# typed: false

# Concern for models that have a collective_id column but should NOT be filtered
# by Collective.current_id in the default scope. This is used for models like:
#
# - RepresentationSession: User representation sessions have NULL collective_id
#   because they can span multiple studios
# - RepresentationSessionEvent: Inherits collective_id from its session,
#   so user representation events also have NULL collective_id
#
# These models still belong_to :collective and have collective_id, but:
# 1. Queries should include records with collective_id matching current OR NULL
# 2. The set_collective_id callback should NOT auto-populate from Collective.current_id
#
module MightNotBelongToCollective
  extend ActiveSupport::Concern

  included do
    # Override to exclude from collective-based filtering in ApplicationRecord's default_scope
    def self.belongs_to_collective?
      false
    end

    # Custom default scope: include records for current collective OR with NULL collective_id
    default_scope do
      if Tenant.current_id
        s = where(tenant_id: Tenant.current_id)
        if Collective.current_id
          s = s.where(collective_id: [Collective.current_id, nil])
        end
        s
      else
        all
      end
    end
  end
end
