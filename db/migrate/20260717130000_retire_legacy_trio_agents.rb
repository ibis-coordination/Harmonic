# The built-in agent formerly known as Trio is retired, succeeded by the
# Trio ensemble of three net-new personas (melody, counterpoint, cadence; see
# Personas) that PersonaActivator seeds fresh when a collective's trio flag
# reconciles. Nothing is renamed or inherited: cadence is a new agent like
# its siblings.
#
# This migration:
#   1. Fail-fast guard: no user or collective may already hold a handle in
#      the newly reserved persona namespaces (cadence/melody/counterpoint,
#      exact or `<tag>-*`). Offenders are listed for manual resolution —
#      notably, a production external agent named "melody" must be retired
#      before this deploys.
#   2. Retires legacy trio agents (system_role "trio") in place: roles
#      stripped, memberships archived, automation rules disabled, funding
#      pool detached. The User rows remain as the historical record —
#      authored content keeps its attribution, and their trio-* handles
#      stay dormant inside the reserved ensemble namespace, resolvable by
#      nothing (@trio resolves through the ensemble role, which they no
#      longer hold).
#   3. Renames the notification-preference key "trio_unavailable" →
#      "persona_unavailable" on tenant_users that customized it.
#
# Collectives whose trio flag is on get the new ensemble seeded on their
# next reconcile (settings save), with fresh default automations — legacy
# rule customizations are retired along with the legacy agent.
class RetireLegacyTrioAgents < ActiveRecord::Migration[7.2]
  NEW_NAMESPACES = %w[cadence melody counterpoint].freeze

  def up
    guard_reserved_namespaces!
    retire_legacy_trio_agents!
    rename_jsonb_key!("tenant_users", %w[notification_preferences trio_unavailable], %w[notification_preferences persona_unavailable])
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Retired trio agents are not automatically restored. Reverse " \
          "manually: re-grant the trio role, unarchive the memberships, and " \
          "re-enable the automation rules for users with system_role 'trio'."
  end

  private

  # Newly reserved namespaces must be empty of squatters before the
  # validation layer starts refusing them — an existing row would make the
  # persona seeder fall back to suffixed handles forever and leave an
  # impersonation-shaped hole. Rows held by the MATCHING system agent are
  # legitimate, not squatters: if the new code went live before this
  # migration ran, a reconcile may already have seeded personas.
  def guard_reserved_namespaces!
    pattern = NEW_NAMESPACES.map { |tag| "(#{Regexp.escape(tag)})(-.*)?" }.join("|")

    offending_users = TenantUser
      .where("handle ~* ?", "^(#{pattern})$")
      .includes(:user)
      .reject { |tu| ReservedHandles.required_system_role(tu.handle) == tu.user&.system_role }
      .map { |tu| "user handle #{tu.handle.inspect} (tenant #{tu.tenant_id}, user #{tu.user_id})" }

    offending_collectives = Collective
      .where("handle ~* ?", "^(#{pattern})$")
      .map { |c| "collective handle #{c.handle.inspect} (id #{c.id})" }

    offenders = offending_users + offending_collectives
    return if offenders.empty?

    raise "Cannot reserve the cadence/melody/counterpoint namespaces — " \
          "existing rows hold reserved handles. Rename or retire them, then " \
          "re-run:\n  #{offenders.join("\n  ")}"
  end

  def retire_legacy_trio_agents!
    User.where(system_role: "trio").find_each do |agent|
      CollectiveMember.where(user_id: agent.id).find_each do |member|
        roles = (member.settings["roles"] || []) - ["trio"]
        member.update_columns(
          settings: member.settings.merge("roles" => roles),
          archived_at: member.archived_at || Time.current,
        )
      end
      AutomationRule.where(ai_agent_id: agent.id).update_all(enabled: false)
      agent.update_columns(funding_pool_id: nil)
    end
  end

  def rename_jsonb_key!(table, from_path, to_path)
    from = "{#{from_path.join(',')}}"
    to = "{#{to_path.join(',')}}"
    execute <<~SQL.squish
      UPDATE #{table}
      SET settings = jsonb_set(settings #- '#{from}', '#{to}', settings #> '#{from}')
      WHERE settings #> '#{from}' IS NOT NULL
    SQL
  end
end
