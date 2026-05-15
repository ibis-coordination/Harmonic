# Recovers collectives whose admin explicitly enabled the Trio feature flag
# but never got a trio_user_id linked. The earlier flag-flip wiring in
# CollectivesController#update_settings used a transition-based check
# (was_enabled vs is_enabled) that misfired when the trio feature flag's
# `default_collective: true` config caused the pre-save read to already
# show "enabled" — so `!was && is` was never true and TrioActivator.activate!
# never ran. The wiring is now reconcile-based; this migration fixes the
# rows that fell into the gap.
#
# Only touches collectives where the flag is set EXPLICITLY in settings
# (settings.feature_flags.trio == true) — not collectives that read as
# "enabled" purely via the config default. Those would only be activated
# when an admin actually saves the settings page, which is the right
# moment to incur the per-collective trio + automation creation.
#
# Idempotent: skips collectives whose trio_user_id is already set. Safe to
# re-run. Cascade through tenant_enabled? is honored — collectives whose
# tenant doesn't have trio enabled at the tenant level are skipped.
class BackfillTrioForOptedInCollectives < ActiveRecord::Migration[7.2]
  def up
    Collective.find_each do |collective|
      next if collective.trio_user_id

      explicit = collective.settings&.dig("feature_flags", "trio")
      next unless explicit.to_s == "true"

      tenant = collective.tenant
      next unless tenant
      next unless tenant.feature_flag_enabled_locally?("trio")

      begin
        Tenant.set_thread_context(tenant)
        TrioActivator.activate!(collective)
      ensure
        Tenant.clear_thread_scope
      end
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Backfilled trio activations cannot be unrolled automatically — " \
          "would require deciding whether to also destroy seeded automation " \
          "rules. Revert by calling TrioActivator.deactivate! on affected " \
          "collectives manually."
  end
end
