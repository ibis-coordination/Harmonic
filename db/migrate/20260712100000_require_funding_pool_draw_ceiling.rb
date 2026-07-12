# Every pool must carry an explicit member daily draw ceiling — "no limit" is
# never an implicit default a member can be surprised by. Runs in the same
# release as the table's creation, so only pre-release dev/test rows can have
# a NULL ceiling; they get a conservative $5.00.
class RequireFundingPoolDrawCeiling < ActiveRecord::Migration[7.2]
  def up
    execute <<~SQL.squish
      UPDATE funding_pools SET member_daily_draw_cap_cents = 500 WHERE member_daily_draw_cap_cents IS NULL
    SQL
    change_column_null :funding_pools, :member_daily_draw_cap_cents, false
  end

  def down
    change_column_null :funding_pools, :member_daily_draw_cap_cents, true
  end
end
