require "test_helper"

class AccountDeletionScrubJobTest < ActiveSupport::TestCase
  setup do
    @original_stripe_key = Stripe.api_key
    Stripe.api_key = "sk_test_fake"
    @tenant = @global_tenant
  end

  teardown do
    Stripe.api_key = @original_stripe_key
  end

  def pending_deletion_user(days_ago:)
    user = create_user(email: "scrub-#{SecureRandom.hex(4)}@example.com", name: "Scrub Target")
    @tenant.add_user!(user)
    user.update!(deletion_requested_at: days_ago.days.ago)
    user
  end

  test "scrubs accounts past the grace window and stamps scrubbed_at" do
    due = pending_deletion_user(days_ago: 31)

    AccountDeletionScrubJob.perform_now

    due.reload
    assert_match(/@deleted\.user$/, due.email)
    assert due.scrubbed_at.present?
  end

  test "leaves accounts inside the grace window untouched" do
    recent = pending_deletion_user(days_ago: 5)

    AccountDeletionScrubJob.perform_now

    recent.reload
    assert_no_match(/@deleted\.user/, recent.email)
    assert_nil recent.scrubbed_at
  end

  test "a failure on one account does not stop the others" do
    blocked = pending_deletion_user(days_ago: 31)
    # Make the scrub fail for this account: Stripe cleanup errors out.
    StripeCustomer.create!(
      billable: blocked, stripe_id: "cus_job_fail", active: true,
      stripe_subscription_id: "sub_job_fail",
    )
    stub_request(:delete, %r{https://api\.stripe\.com/v1/subscriptions/sub_job_fail})
      .to_return(status: 500, body: { error: { message: "boom" } }.to_json)
    healthy = pending_deletion_user(days_ago: 31)

    AccountDeletionScrubJob.perform_now

    assert_no_match(/@deleted\.user/, blocked.reload.email, "the failing account is skipped, retried next run")
    assert_nil blocked.scrubbed_at
    assert_match(/@deleted\.user$/, healthy.reload.email, "other accounts still get scrubbed")
  end

  test "an account restored after batch selection is not scrubbed" do
    # Simulates a restore landing between the job's query and this user's
    # turn in the batch: scrub_one must re-check state, not trust the batch.
    restored = pending_deletion_user(days_ago: 31)
    restored.update!(deletion_requested_at: nil)

    AccountDeletionScrubJob.new.scrub_one(restored)

    assert_no_match(/@deleted\.user/, restored.reload.email)
    assert_nil restored.scrubbed_at
  end

  test "already-scrubbed accounts are not re-selected" do
    done = pending_deletion_user(days_ago: 40)
    done.update!(scrubbed_at: 9.days.ago, email: "#{SecureRandom.hex(10)}@deleted.user")

    AccountDeletionScrubJob.perform_now

    assert_equal 9.days.ago.to_date, done.reload.scrubbed_at.to_date, "scrubbed_at must not be restamped"
  end

  # === per-subdomain slices ===

  def pending_tenant_deletion_user(days_ago:)
    user = create_user(email: "slice-#{SecureRandom.hex(4)}@example.com", name: "Slice Target")
    @tenant.add_user!(user)
    tenant_b = create_tenant
    tenant_b.add_user!(user)
    tu = TenantUser.tenant_scoped_only(@tenant.id).find_by(user_id: user.id)
    tu.update!(deletion_requested_at: days_ago.days.ago)
    [user, tu, tenant_b]
  end

  test "scrubs tenant slices past the grace window without touching the rest of the account" do
    user, tu, tenant_b = pending_tenant_deletion_user(days_ago: 31)
    original_email = user.email

    AccountDeletionScrubJob.perform_now

    tu.reload
    assert_equal "Deleted User", tu.display_name
    assert tu.scrubbed_at.present?
    assert_equal original_email, user.reload.email, "the account survives elsewhere"
    assert_nil user.scrubbed_at
    tu_b = TenantUser.tenant_scoped_only(tenant_b.id).find_by(user_id: user.id)
    assert_nil tu_b.scrubbed_at, "the other subdomain's slice is untouched"
  end

  test "leaves tenant slices inside the grace window untouched" do
    _user, tu, = pending_tenant_deletion_user(days_ago: 5)

    AccountDeletionScrubJob.perform_now

    assert_nil tu.reload.scrubbed_at
    assert_not_equal "Deleted User", tu.display_name
  end

  test "tenant_scrub_due matches only human tenant slices past the grace period" do
    user = create_user(email: "due-#{SecureRandom.hex(4)}@example.com", name: "Due Target")
    @tenant.add_user!(user)
    agent = create_ai_agent(parent: user)
    @tenant.add_user!(agent)
    tenant_b = create_tenant
    tenant_b.add_user!(user)
    AccountDeletionService.request_tenant_deletion!(user: user, tenant: @tenant)
    tu = TenantUser.tenant_scoped_only(@tenant.id).find_by(user_id: user.id)
    agent_tu = TenantUser.tenant_scoped_only(@tenant.id).find_by(user_id: agent.id)

    assert_not_includes AccountDeletionScrubJob.tenant_scrub_due, tu, "inside grace window"

    past_grace = (AccountDeletionService::GRACE_PERIOD + 1.day).ago
    tu.update!(deletion_requested_at: past_grace)
    agent_tu.update!(deletion_requested_at: past_grace)
    assert_includes AccountDeletionScrubJob.tenant_scrub_due, tu, "past grace window"
    assert_not_includes AccountDeletionScrubJob.tenant_scrub_due, agent_tu,
                        "agent slices are scrubbed with their principal's, never selected directly"

    user.update!(deletion_requested_at: 1.day.ago)
    assert_not_includes AccountDeletionScrubJob.tenant_scrub_due, tu,
                        "globally pending users are handled by the global scrub"
    user.update!(deletion_requested_at: nil)

    tu.update!(scrubbed_at: Time.current)
    assert_not_includes AccountDeletionScrubJob.tenant_scrub_due, tu, "already scrubbed"
  end

  test "a tenant slice restored after batch selection is not scrubbed" do
    _user, tu, = pending_tenant_deletion_user(days_ago: 31)
    original_handle = tu.handle
    tu.update!(deletion_requested_at: nil)

    AccountDeletionScrubJob.new.scrub_one_tenant_user(tu)

    assert_equal original_handle, tu.reload.handle
    assert_nil tu.scrubbed_at
  end
end
