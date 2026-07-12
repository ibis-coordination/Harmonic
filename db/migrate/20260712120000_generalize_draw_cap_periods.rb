# Draw ceilings become (amount, period) pairs — day, week, or month windows —
# instead of hardwired daily. Every UI surface still writes "day"; the period
# dimension sits dormant until the UI grows period selectors. Runs in the same
# release as the columns' creation, so the rename ships before any deploy has
# the old names.
class GeneralizeDrawCapPeriods < ActiveRecord::Migration[7.2]
  def change
    rename_column :funding_pools, :member_daily_draw_cap_cents, :member_draw_cap_cents
    add_column :funding_pools, :member_draw_cap_period, :string, null: false, default: "day"
    rename_column :funding_pool_enrollments, :daily_draw_cap_cents, :draw_cap_cents
    add_column :funding_pool_enrollments, :draw_cap_period, :string, null: false, default: "day"
  end
end
