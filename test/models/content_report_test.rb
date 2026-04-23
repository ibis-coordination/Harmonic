require "test_helper"

class ContentReportTest < ActiveSupport::TestCase
  def setup
    @tenant, @collective, @user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @other_user = create_user(email: "reporter-#{SecureRandom.hex(4)}@example.com", name: "Reporter")
    @tenant.add_user!(@other_user)
    @collective.add_user!(@other_user)
    @note = create_note(text: "Some content", created_by: @user)
  end

  test "ContentReport.create works" do
    report = ContentReport.create!(
      reporter: @other_user,
      reportable: @note,
      tenant: @tenant,
      reason: "spam",
    )

    assert report.persisted?
    assert_equal @other_user, report.reporter
    assert_equal @note, report.reportable
    assert_equal "spam", report.reason
    assert_equal "pending", report.status
  end

  test "reason must be valid" do
    report = ContentReport.new(
      reporter: @other_user,
      reportable: @note,
      tenant: @tenant,
      reason: "invalid_reason",
    )

    assert_not report.valid?
    assert_includes report.errors[:reason], "is not included in the list"
  end

  test "all valid reasons are accepted" do
    %w[harassment spam inappropriate misinformation other].each do |reason|
      report = ContentReport.new(
        reporter: @other_user,
        reportable: @note,
        tenant: @tenant,
        reason: reason,
      )
      assert report.valid?, "#{reason} should be a valid reason"
      # Clean up to avoid uniqueness violation
    end
  end

  test "cannot report your own content" do
    report = ContentReport.new(
      reporter: @user,
      reportable: @note,
      tenant: @tenant,
      reason: "spam",
    )

    assert_not report.valid?
    assert_includes report.errors[:reporter_id], "cannot report your own content"
  end

  test "duplicate report is rejected" do
    ContentReport.create!(
      reporter: @other_user,
      reportable: @note,
      tenant: @tenant,
      reason: "spam",
    )

    duplicate = ContentReport.new(
      reporter: @other_user,
      reportable: @note,
      tenant: @tenant,
      reason: "harassment",
    )

    assert_not duplicate.valid?
  end

  test "description is optional" do
    report = ContentReport.create!(
      reporter: @other_user,
      reportable: @note,
      tenant: @tenant,
      reason: "other",
      description: "This is very offensive content.",
    )

    assert_equal "This is very offensive content.", report.description
  end

  test "review! updates status and reviewer" do
    admin = create_user(email: "admin-#{SecureRandom.hex(4)}@example.com", name: "Admin")
    report = ContentReport.create!(
      reporter: @other_user,
      reportable: @note,
      tenant: @tenant,
      reason: "spam",
    )

    report.review!(admin: admin, status: "dismissed", notes: "Not actually spam")

    assert_equal "dismissed", report.status
    assert_equal admin, report.reviewed_by
    assert_equal "Not actually spam", report.admin_notes
    assert_not_nil report.reviewed_at
  end

  test "status must be valid" do
    report = ContentReport.new(
      reporter: @other_user,
      reportable: @note,
      tenant: @tenant,
      reason: "spam",
      status: "bogus",
    )

    assert_not report.valid?
    assert_includes report.errors[:status], "is not included in the list"
  end

  test "pending scope returns only pending reports" do
    ContentReport.create!(reporter: @other_user, reportable: @note, tenant: @tenant, reason: "spam")

    decision = create_decision(question: "Some decision", created_by: @user)
    reviewed = ContentReport.create!(reporter: @other_user, reportable: decision, tenant: @tenant, reason: "harassment")
    reviewed.update!(status: "dismissed")

    pending_reports = ContentReport.pending
    assert pending_reports.any? { |r| r.reportable == @note }
    assert_not pending_reports.any? { |r| r.reportable == decision }
  end
end
