# typed: false

# Concern for models that have a superagent_id column but should NOT be filtered
# by Superagent.current_id in the default scope. This is used for models like:
#
# - RepresentationSession: User representation sessions have NULL superagent_id
#   because they can span multiple studios
# - RepresentationSessionAssociation: Inherits superagent_id from its session,
#   so user representation associations also have NULL superagent_id
#
# These models still belong_to :superagent and have superagent_id, but:
# 1. Queries should include records with superagent_id matching current OR NULL
# 2. The set_superagent_id callback should NOT auto-populate from Superagent.current_id
#
module MightNotBelongToSuperagent
  extend ActiveSupport::Concern

  included do
    # Override to exclude from superagent-based filtering in ApplicationRecord's default_scope
    def self.belongs_to_superagent?
      false
    end

    # Custom default scope: include records for current superagent OR with NULL superagent_id
    default_scope do
      if Tenant.current_id
        s = where(tenant_id: Tenant.current_id)
        if Superagent.current_id
          s = s.where(superagent_id: [Superagent.current_id, nil])
        end
        s
      else
        all
      end
    end
  end
end
