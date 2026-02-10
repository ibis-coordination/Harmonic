# typed: false

# Creates TrusteeGrants for existing subagent users that have a parent but don't already have a grant.
# This backfills the trustee grant relationship for subagents created before the TrusteeGrant system.
class CreateTrusteeGrantsForExistingSubagents < ActiveRecord::Migration[7.0]
  def up
    # Find all subagent users with a parent that don't already have a TrusteeGrant
    subagents_without_grants = User.unscoped
                                   .where(user_type: "subagent")
                                   .where.not(parent_id: nil)
                                   .where.not(
                                     id: TrusteeGrant.unscoped.select(:granting_user_id)
                                   )

    # Grant all available actions
    all_permissions = TrusteeGrant::GRANTABLE_ACTIONS.index_with { true }

    subagents_without_grants.find_each do |subagent|
      parent_user = User.unscoped.find_by(id: subagent.parent_id)
      next unless parent_user

      # Get the tenant for this subagent via their tenant_user
      tenant_user = TenantUser.unscoped.find_by(user_id: subagent.id)
      next unless tenant_user

      # The model's before_validation callback creates the trustee_user automatically
      TrusteeGrant.create!(
        tenant: tenant_user.tenant,
        granting_user: subagent,
        trusted_user: parent_user,
        accepted_at: Time.current,
        permissions: all_permissions,
        studio_scope: { "mode" => "all" },
      )
    end
  end

  def down
    # Delete TrusteeGrants created for subagent-parent relationships
    User.unscoped.where(user_type: "subagent").where.not(parent_id: nil).find_each do |subagent|
      grant = TrusteeGrant.unscoped.find_by(
        granting_user_id: subagent.id,
        trusted_user_id: subagent.parent_id,
      )
      next unless grant

      trustee_user = grant.trustee_user

      # Delete representation sessions and associations referencing this grant
      rep_session_ids = RepresentationSession.unscoped.where(trustee_grant_id: grant.id).pluck(:id)
      RepresentationSessionAssociation.unscoped.where(representation_session_id: rep_session_ids).delete_all
      RepresentationSession.unscoped.where(id: rep_session_ids).delete_all

      grant.delete

      if trustee_user
        TenantUser.unscoped.where(user_id: trustee_user.id).delete_all
        begin
          trustee_user.delete
        rescue ActiveRecord::InvalidForeignKey
          # User has activity, leave it as orphaned
        end
      end
    end
  end
end
