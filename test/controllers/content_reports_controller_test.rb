require "test_helper"

class ContentReportsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    @other_user = create_user(email: "author-#{SecureRandom.hex(4)}@example.com", name: "Author")
    @tenant.add_user!(@other_user)
    @collective.add_user!(@other_user)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @note = create_note(text: "Some content to report", created_by: @other_user)
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  # === Unauthenticated Access ===

  test "unauthenticated user is redirected from report form" do
    get "/content-reports/new?reportable_type=Note&reportable_id=#{@note.id}"
    assert_response :redirect
  end

  # === New (report form) ===

  test "user can view report form" do
    sign_in_as(@user, tenant: @tenant)

    get "/content-reports/new?reportable_type=Note&reportable_id=#{@note.id}"

    assert_response :success
    assert_match "Report", response.body
  end

  # === Create ===

  test "user can submit a content report" do
    sign_in_as(@user, tenant: @tenant)

    assert_difference "ContentReport.count", 1 do
      post "/content-reports", params: {
        reportable_type: "Note",
        reportable_id: @note.id,
        reason: "spam",
        description: "This is spam content",
      }
    end

    assert_response :redirect
    report = ContentReport.last
    assert_equal "spam", report.reason
    assert_equal "This is spam content", report.description
    assert_equal @user.id, report.reporter_id
    assert_equal "pending", report.status
  end

  test "user cannot report their own content" do
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    own_note = create_note(text: "My own note", created_by: @user)

    sign_in_as(@user, tenant: @tenant)

    assert_no_difference "ContentReport.count" do
      post "/content-reports", params: {
        reportable_type: "Note",
        reportable_id: own_note.id,
        reason: "spam",
      }
    end

    assert_response :redirect
    assert_match "cannot report your own content", flash[:alert]
  end
end
