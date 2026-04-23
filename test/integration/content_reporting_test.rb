require "test_helper"

class ContentReportingTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    @other_user = create_user(email: "author-#{SecureRandom.hex(4)}@example.com", name: "Author")
    @tenant.add_user!(@other_user)
    @collective.add_user!(@other_user)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  # === Phase 1: Report button on show pages ===

  # -- Notes --

  test "report link shown on other user's note" do
    note = create_note(text: "Reportable content", created_by: @other_user)
    sign_in_as(@user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/n/#{note.truncated_id}"

    assert_response :success
    assert_match "Report", response.body
    assert_match "/report", response.body
  end

  test "report link not shown on own note" do
    note = create_note(text: "My own content", created_by: @user)
    sign_in_as(@user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/n/#{note.truncated_id}"

    assert_response :success
    assert_no_match(/\/report"/, response.body)
  end

  test "report link not shown on deleted note" do
    note = create_note(text: "Deleted content", created_by: @other_user)
    note.soft_delete!(by: @other_user)
    sign_in_as(@user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/n/#{note.truncated_id}"

    assert_response :success
    assert_no_match(/\/report"/, response.body)
  end

  test "report link not shown when already reported note" do
    note = create_note(text: "Already reported", created_by: @other_user)
    ContentReport.create!(
      reporter: @user,
      reportable: note,
      tenant: @tenant,
      reason: "spam",
    )
    sign_in_as(@user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/n/#{note.truncated_id}"

    assert_response :success
    assert_no_match(/\/report"/, response.body)
  end

  test "report link not shown when not logged in" do
    note = create_note(text: "Content", created_by: @other_user)

    get "/collectives/#{@collective.handle}/n/#{note.truncated_id}"

    # May redirect to login or show page without report link — either way, no report link
    if response.redirect?
      assert_no_match(/\/report"/, response.body)
    else
      assert_response :success
      assert_no_match(/\/report"/, response.body)
    end
  end

  test "unauthenticated user is redirected from report form" do
    note = create_note(text: "Content", created_by: @other_user)

    get "#{note.path}/report"

    assert_response :redirect
  end

  # -- Decisions --

  test "report link shown on other user's decision" do
    decision = create_decision(question: "Reportable?", created_by: @other_user)
    sign_in_as(@user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/d/#{decision.truncated_id}"

    assert_response :success
    assert_match "Report", response.body
    assert_match "/report", response.body
  end

  test "report link not shown on own decision" do
    decision = create_decision(question: "My decision", created_by: @user)
    sign_in_as(@user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/d/#{decision.truncated_id}"

    assert_response :success
    assert_no_match(/\/report"/, response.body)
  end

  # -- Commitments --

  test "report link shown on other user's commitment" do
    commitment = create_commitment(title: "Reportable", created_by: @other_user)
    sign_in_as(@user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/c/#{commitment.truncated_id}"

    assert_response :success
    assert_match "Report", response.body
    assert_match "/report", response.body
  end

  test "report link not shown on own commitment" do
    commitment = create_commitment(title: "My commitment", created_by: @user)
    sign_in_as(@user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/c/#{commitment.truncated_id}"

    assert_response :success
    assert_no_match(/\/report"/, response.body)
  end

  # === Content snapshot on report creation ===

  test "content snapshot is captured when report is created" do
    note = create_note(text: "This is the original text", title: "Original Title", created_by: @other_user)
    sign_in_as(@user, tenant: @tenant)

    post "#{note.path}/actions/report_content", params: { reason: "spam" }

    report = ContentReport.last
    assert_not_nil report.content_snapshot
    snapshot = JSON.parse(report.content_snapshot)
    assert_equal "Original Title", snapshot["title"]
    assert_equal "This is the original text", snapshot["text"]
  end

  test "content snapshot preserves text even after content is edited" do
    note = create_note(text: "Original text before edit", created_by: @other_user)
    sign_in_as(@user, tenant: @tenant)

    post "#{note.path}/actions/report_content", params: { reason: "harassment" }

    # Simulate editing the note after report
    note.update!(text: "Edited text after report")

    report = ContentReport.last
    snapshot = JSON.parse(report.content_snapshot)
    assert_equal "Original text before edit", snapshot["text"]
  end

  test "content snapshot works for decisions" do
    decision = create_decision(question: "Bad question?", created_by: @other_user)
    sign_in_as(@user, tenant: @tenant)

    post "#{decision.path}/actions/report_content", params: { reason: "inappropriate" }

    report = ContentReport.last
    snapshot = JSON.parse(report.content_snapshot)
    assert_equal "Bad question?", snapshot["question"]
  end

  test "content snapshot works for commitments" do
    commitment = create_commitment(title: "Bad commitment", created_by: @other_user)
    sign_in_as(@user, tenant: @tenant)

    post "#{commitment.path}/actions/report_content", params: { reason: "misinformation" }

    report = ContentReport.last
    snapshot = JSON.parse(report.content_snapshot)
    assert_equal "Bad commitment", snapshot["title"]
  end

  # === Report form ===

  test "report form shows content preview" do
    note = create_note(text: "Some problematic content here", created_by: @other_user)
    sign_in_as(@user, tenant: @tenant)

    get "#{note.path}/report"

    assert_response :success
    assert_match "Some problematic content", response.body
    assert_match @other_user.name, response.body
  end

  test "report form shows also block checkbox" do
    note = create_note(text: "Content", created_by: @other_user)
    sign_in_as(@user, tenant: @tenant)

    get "#{note.path}/report"

    assert_response :success
    assert_match "also_block", response.body
  end

  # === Combined report + block ===

  test "report with also_block creates both report and block" do
    note = create_note(text: "Content", created_by: @other_user)
    sign_in_as(@user, tenant: @tenant)

    assert_difference ["ContentReport.count", "UserBlock.count"], 1 do
      post "#{note.path}/actions/report_content", params: { reason: "harassment", also_block: "1" }
    end

    assert_response :redirect
    block = UserBlock.last
    assert_equal @user.id, block.blocker_id
    assert_equal @other_user.id, block.blocked_id
  end

  test "report without also_block does not create block" do
    note = create_note(text: "Content", created_by: @other_user)
    sign_in_as(@user, tenant: @tenant)

    assert_difference "ContentReport.count", 1 do
      assert_no_difference "UserBlock.count" do
        post "#{note.path}/actions/report_content", params: { reason: "spam" }
      end
    end
  end

  test "report with also_block does not duplicate existing block" do
    note = create_note(text: "Content", created_by: @other_user)
    UserBlock.create!(blocker: @user, blocked: @other_user, tenant: @tenant)
    sign_in_as(@user, tenant: @tenant)

    assert_difference "ContentReport.count", 1 do
      assert_no_difference "UserBlock.count" do
        post "#{note.path}/actions/report_content", params: { reason: "harassment", also_block: "1" }
      end
    end
  end

  # === Deleted content ===

  test "cannot report deleted content" do
    note = create_note(text: "Will be deleted", created_by: @other_user)
    deleted_note_path = note.path
    note.soft_delete!(by: @other_user)
    sign_in_as(@user, tenant: @tenant)

    assert_no_difference "ContentReport.count" do
      post "#{deleted_note_path}/actions/report_content", params: { reason: "spam" }
    end
  end

  test "flash message mentions block when also_block is checked" do
    note = create_note(text: "Content", created_by: @other_user)
    sign_in_as(@user, tenant: @tenant)

    post "#{note.path}/actions/report_content", params: { reason: "harassment", also_block: "1" }

    assert_match "blocked", flash[:notice]
  end

  # === Markdown show views ===

  # === Actions API ===

  test "report_content action appears in markdown show for other user's note" do
    note = create_note(text: "Reportable", created_by: @other_user)
    sign_in_as(@user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/n/#{note.truncated_id}", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match "report_content", response.body
  end

  test "report_content action not in markdown show for own note" do
    note = create_note(text: "My note", created_by: @user)
    sign_in_as(@user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/n/#{note.truncated_id}", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_no_match(/report_content/, response.body)
  end

  test "report_content action works via POST" do
    note = create_note(text: "Bad content", created_by: @other_user)
    sign_in_as(@user, tenant: @tenant)

    assert_difference "ContentReport.count", 1 do
      post "/collectives/#{@collective.handle}/n/#{note.truncated_id}/actions/report_content",
           params: { reason: "spam", description: "This is spam" },
           headers: { "Accept" => "text/markdown" }
    end

    assert_response :success
    report = ContentReport.last
    assert_equal "spam", report.reason
    assert_equal "This is spam", report.description
    assert_equal @user.id, report.reporter_id
    assert_equal "pending", report.status
    assert_not_nil report.content_snapshot
  end

  test "report_content action works for decisions" do
    decision = create_decision(question: "Bad?", created_by: @other_user)
    sign_in_as(@user, tenant: @tenant)

    assert_difference "ContentReport.count", 1 do
      post "/collectives/#{@collective.handle}/d/#{decision.truncated_id}/actions/report_content",
           params: { reason: "harassment" },
           headers: { "Accept" => "text/markdown" }
    end

    assert_response :success
  end

  test "report_content action works for commitments" do
    commitment = create_commitment(title: "Bad", created_by: @other_user)
    sign_in_as(@user, tenant: @tenant)

    assert_difference "ContentReport.count", 1 do
      post "/collectives/#{@collective.handle}/c/#{commitment.truncated_id}/actions/report_content",
           params: { reason: "inappropriate" },
           headers: { "Accept" => "text/markdown" }
    end

    assert_response :success
  end

  test "report_content action rejects reporting own content" do
    note = create_note(text: "My content", created_by: @user)
    sign_in_as(@user, tenant: @tenant)

    assert_no_difference "ContentReport.count" do
      post "/collectives/#{@collective.handle}/n/#{note.truncated_id}/actions/report_content",
           params: { reason: "spam" },
           headers: { "Accept" => "text/markdown" }
    end
  end

  test "report_content action with also_block creates block" do
    note = create_note(text: "Bad", created_by: @other_user)
    sign_in_as(@user, tenant: @tenant)

    assert_difference ["ContentReport.count", "UserBlock.count"], 1 do
      post "/collectives/#{@collective.handle}/n/#{note.truncated_id}/actions/report_content",
           params: { reason: "harassment", also_block: "1" },
           headers: { "Accept" => "text/markdown" }
    end
  end

  test "markdown report form shows content details" do
    note = create_note(text: "Problematic content", created_by: @other_user)
    sign_in_as(@user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/n/#{note.truncated_id}/report", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match "Report Content", response.body
    assert_match @other_user.handle, response.body
    assert_match "Problematic content", response.body
    assert_match "report_content", response.body
  end

  test "markdown note show includes report link for other user's content" do
    note = create_note(text: "Reportable content", created_by: @other_user)
    sign_in_as(@user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/n/#{note.truncated_id}", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match "Report this note", response.body
    assert_match "/report", response.body
  end

  test "markdown note show does not include report link for own content" do
    note = create_note(text: "My content", created_by: @user)
    sign_in_as(@user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/n/#{note.truncated_id}", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_no_match(/\/report"/, response.body)
  end

  test "markdown decision show includes report link for other user's content" do
    decision = create_decision(question: "Reportable?", created_by: @other_user)
    sign_in_as(@user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/d/#{decision.truncated_id}", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match "Report this decision", response.body
  end

  test "markdown commitment show includes report link for other user's content" do
    commitment = create_commitment(title: "Reportable", created_by: @other_user)
    sign_in_as(@user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/c/#{commitment.truncated_id}", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match "Report this commitment", response.body
  end
end
