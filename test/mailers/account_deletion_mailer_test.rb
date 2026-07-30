# typed: false

require "test_helper"

class AccountDeletionMailerTest < ActiveSupport::TestCase
  setup do
    @tenant = @global_tenant
    @user = @global_user
    @scrub_date = (Time.current + AccountDeletionService::GRACE_PERIOD).to_date
  end

  test "deletion_requested (global) states the date and the restore path" do
    email = AccountDeletionMailer.deletion_requested(user: @user, tenant: @tenant, scrub_date: @scrub_date)

    assert_equal [@user.email], email.to
    assert_includes email.subject, "scheduled for deletion"
    body = email.body.encoded
    assert_includes body, @scrub_date.to_fs(:long)
    assert_includes body, "/account/deletion"
    assert_includes body, "Deleted User"
  end

  test "deletion_requested (per-subdomain) names the subdomain" do
    email = AccountDeletionMailer.deletion_requested(
      user: @user, tenant: @tenant, scrub_date: @scrub_date, subdomain_only: true,
    )

    assert_equal [@user.email], email.to
    assert_includes email.subject, @tenant.subdomain
    body = email.body.encoded
    assert_includes body, @tenant.subdomain
    assert_includes body, "other subdomains are not affected"
  end

  test "deletion_reminder states the deletion date and the restore path" do
    email = AccountDeletionMailer.deletion_reminder(user: @user, tenant: @tenant, scrub_date: @scrub_date)

    assert_equal [@user.email], email.to
    assert_includes email.subject, "permanently deleted"
    body = email.body.encoded
    assert_includes body, @scrub_date.to_fs(:long)
    assert_includes body, "/account/deletion"
  end

  test "deletion_reminder (per-subdomain) names the subdomain" do
    email = AccountDeletionMailer.deletion_reminder(
      user: @user, tenant: @tenant, scrub_date: @scrub_date, subdomain_only: true,
    )

    assert_includes email.subject, @tenant.subdomain
  end
end
