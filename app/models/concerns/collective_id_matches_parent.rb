# typed: false

# Enforces that this model's collective_id equals the named parent's collective_id.
# Without this, ApplicationRecord#set_collective_id may pull from Collective.current_id
# and end up out of sync with the parent record's collective, producing orphan rows
# that evade collective-scoped cleanup.
module CollectiveIdMatchesParent
  extend ActiveSupport::Concern

  class_methods do
    def collective_id_matches(parent_name)
      validate do
        parent = public_send(parent_name)
        next if parent.nil? || collective_id.nil?
        if collective_id != parent.collective_id
          errors.add(:collective_id, "must match #{parent_name} collective_id")
        end
      end
    end
  end
end
