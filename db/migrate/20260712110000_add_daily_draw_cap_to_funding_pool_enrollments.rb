# Enrollment is consent, and consent needs a number: every enrollee states
# their own daily draw ceiling when they enroll, so no member's exposure ever
# rests on an implicitly assumed limit. The effective per-member ceiling at
# draw time is min(pool ceiling, member ceiling). Runs in the same release as
# the table's creation, so only pre-release dev/test rows need the backfill
# from their pool's ceiling.
class AddDailyDrawCapToFundingPoolEnrollments < ActiveRecord::Migration[7.2]
  def up
    add_column :funding_pool_enrollments, :daily_draw_cap_cents, :integer
    execute <<~SQL.squish
      UPDATE funding_pool_enrollments
      SET daily_draw_cap_cents = funding_pools.member_daily_draw_cap_cents
      FROM funding_pools
      WHERE funding_pool_enrollments.funding_pool_id = funding_pools.id
        AND funding_pool_enrollments.daily_draw_cap_cents IS NULL
    SQL
    change_column_null :funding_pool_enrollments, :daily_draw_cap_cents, false
  end

  def down
    remove_column :funding_pool_enrollments, :daily_draw_cap_cents
  end
end
