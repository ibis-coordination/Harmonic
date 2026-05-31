# Private workspaces were created with billing_exempt: true by default, on
# the assumption that workspaces never bill. With the free/paid tier model,
# workspaces now bill the same as standard collectives — they're free
# unless they have a paid feature active (enabled automation, trio,
# file_attachments). Clearing billing_exempt makes existing workspaces
# eligible for paid-tier billing in line with their new behavior.
#
# Safe: no workspaces have paid features today (trio and file_attachments
# are new; automations weren't user-creatable on workspaces). The flag flip
# alone doesn't trigger any charges — `paid_tier?` is still false until an
# admin actually enables a paid feature.
class ClearBillingExemptOnPrivateWorkspaces < ActiveRecord::Migration[7.2]
  def up
    Collective.where(collective_type: "private_workspace", billing_exempt: true)
      .update_all(billing_exempt: false) # rubocop:disable Rails/SkipsModelValidations
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Cannot tell which workspaces were originally admin-set vs default-set."
  end
end
