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
  # Frozen after the trio→cadence persona rename: the TrioActivator this
  # backfill delegated to no longer exists. No-ops on a clean chain (no
  # collectives with an explicit trio flag exist at this point); fails fast
  # on a restored pre-2026-05 backup.
  def up
    opted_in = Collective.find_each.any? do |collective|
      collective.settings&.dig("feature_flags", "trio").to_s == "true" && collective.trio_user_id.nil?
    end
    return unless opted_in

    raise "BackfillTrioForOptedInCollectives cannot replay after the trio→cadence rename. "           "Finish the migration chain, then reconcile personas via PersonaActivator.reconcile!."
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Backfilled trio activations cannot be unrolled automatically — " \
          "would require deciding whether to also destroy seeded automation " \
          "rules. Revert by calling TrioActivator.deactivate! on affected " \
          "collectives manually."
  end
end
