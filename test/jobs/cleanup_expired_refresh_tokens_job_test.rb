require "test_helper"

class CleanupExpiredRefreshTokensJobTest < ActiveSupport::TestCase
  setup do
    @user = create_user
  end

  test "deletes tokens expired for longer than the retention period" do
    stale = RefreshToken.issue!(user: @user)
    stale.update!(expires_at: 31.days.ago)

    CleanupExpiredRefreshTokensJob.perform_now

    assert_not RefreshToken.exists?(stale.id), "long-expired tokens must be deleted"
  end

  test "keeps recently expired and live tokens" do
    recently_expired = RefreshToken.issue!(user: @user)
    recently_expired.update!(expires_at: 1.day.ago)
    live = RefreshToken.issue!(user: @user)

    CleanupExpiredRefreshTokensJob.perform_now

    assert RefreshToken.exists?(recently_expired.id), "recently expired tokens must survive the grace window"
    assert RefreshToken.exists?(live.id), "live tokens must never be touched"
  end

  test "deletes rotated and revoked tokens once long-expired" do
    rotated = RefreshToken.issue!(user: @user)
    rotated.update!(rotated_at: 40.days.ago, expires_at: 31.days.ago)
    revoked = RefreshToken.issue!(user: @user)
    revoked.update!(revoked_at: 40.days.ago, revoked_reason: "admin", expires_at: 31.days.ago)

    CleanupExpiredRefreshTokensJob.perform_now

    assert_not RefreshToken.exists?(rotated.id)
    assert_not RefreshToken.exists?(revoked.id)
  end
end
