require "test_helper"

class MarkdownUiTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @studio = @global_studio
    @studio.enable_api!
    @user = @global_user
    @api_token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.valid_scopes,
    )
    @headers = {
      "Authorization" => "Bearer #{@api_token.token}",
      "Accept" => "text/markdown",
      "Content-Type" => "application/json",
    }
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  def is_markdown?
    response.content_type.starts_with?("text/markdown") &&
    response.body.start_with?("---\napp: Harmonic")
  end

  def has_nav_bar?
    response.body.include?("\n---\nnav: | [Home](/) |")
  end

  def has_actions_section?
    response.body.include?("# Actions")
  end

  def page_title
    m = response.body.match(/title: (.+)/)
    m ? m[1] : nil
  end

  def page_path
    m = response.body.match(/path: (.+)/)
    m ? m[1] : nil
  end

  def assert_200_markdown_response(title, path, params: nil)
    if params
      post path, params: params, headers: @headers
    else
      get path, headers: @headers
    end
    assert_equal 200, response.status
    assert is_markdown?, "'#{path}' does not return markdown"
    assert has_nav_bar?, "'#{path}' does not have a nav bar"
    assert has_actions_section?, "'#{path}' does not have actions section"
    assert_equal title, page_title, "Page title '#{page_title}' does not match expected '#{title}'"
    assert_equal path, page_path, "Page path '#{page_path}' does not match expected '#{path}'"
  end

  def assert_200_markdown_page_with_actions(title, path)
    assert_200_markdown_response(title, path)
    path = '' if path == '/'
    assert_200_markdown_response("Actions | #{title}", "#{path}/actions")
  end

  test "GET / returns 200 markdown with actions" do
    assert_200_markdown_page_with_actions("Home", "/")
  end

  test "GET /studios/new returns 200 markdown with actions" do
    assert_200_markdown_page_with_actions("New Studio", "/studios/new")
  end

  test "GET /studios/:studio_handle returns 200 markdown with actions" do
    assert_200_markdown_page_with_actions(@studio.name, "/studios/#{@studio.handle}")
  end

  test "GET /studios/:studio_handle/note returns 200 markdown with actions" do
    assert_200_markdown_page_with_actions("Note", "/studios/#{@studio.handle}/note")
  end

  test "GET /studios/:studio_handle/decide returns 200 markdown with actions" do
    assert_200_markdown_page_with_actions("Decide", "/studios/#{@studio.handle}/decide")
  end

  # Cycle detail pages
  test "GET /studios/:studio_handle/cycles returns 200 markdown" do
    get "/studios/#{@studio.handle}/cycles", headers: @headers
    assert_equal 200, response.status
    assert is_markdown?
  end

  test "GET /studios/:studio_handle/cycles/today returns 200 markdown" do
    get "/studios/#{@studio.handle}/cycles/today", headers: @headers
    assert_equal 200, response.status
    assert is_markdown?
  end

  # Decision actions
  test "POST add_option action on decision returns 200 markdown" do
    decision = create_decision(studio: @studio, created_by: @user, question: "Test decision?")
    post "/studios/#{@studio.handle}/d/#{decision.truncated_id}/actions/add_option",
      params: { title: "Test option" }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?
  end

  # Commitment actions
  test "POST join_commitment action returns 200 markdown" do
    commitment = create_commitment(studio: @studio, created_by: @user, title: "Test commitment")
    post "/studios/#{@studio.handle}/c/#{commitment.truncated_id}/actions/join_commitment",
      params: {}.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?
  end

  # Heartbeat gate tests
  test "studio homepage without heartbeat shows only send_heartbeat action" do
    # Ensure no heartbeat exists for this cycle
    Heartbeat.where(studio: @studio, user: @user).delete_all

    get "/studios/#{@studio.handle}", headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Should show heartbeat required message
    assert response.body.include?("Heartbeat Required"),
      "Should show heartbeat required message"

    # Should include the send_heartbeat action
    assert response.body.include?("send_heartbeat"),
      "Should include send_heartbeat action"

    # Should NOT show full studio content (like pinned items, team, new note/decision/commit actions)
    refute response.body.include?("## Team"),
      "Should NOT show Team section when heartbeat missing"
    refute response.body.include?("[New Note]"),
      "Should NOT show New Note action when heartbeat missing"
  end

  test "studio homepage with heartbeat shows full content" do
    # Create a heartbeat for the current cycle
    heartbeat = Heartbeat.create!(
      tenant: @tenant,
      studio: @studio,
      user: @user,
      expires_at: 1.day.from_now,
    )

    get "/studios/#{@studio.handle}", headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Should NOT show heartbeat required message
    refute response.body.include?("Heartbeat Required"),
      "Should NOT show heartbeat required when heartbeat exists"

    # Should show full studio content
    assert response.body.include?("## Team"),
      "Should show Team section when heartbeat exists"
    assert response.body.include?("[New Note]"),
      "Should show New Note action when heartbeat exists"
  ensure
    heartbeat&.destroy
  end

  test "POST send_heartbeat action creates heartbeat and returns 200" do
    # Ensure no heartbeat exists
    Heartbeat.where(studio: @studio, user: @user).delete_all

    post "/studios/#{@studio.handle}/actions/send_heartbeat",
      params: {}.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Verify heartbeat was created
    assert Heartbeat.where(studio: @studio, user: @user).exists?,
      "Heartbeat should have been created"
  ensure
    Heartbeat.where(studio: @studio, user: @user).delete_all
  end

  # add_comment action tests
  test "POST add_comment action on note returns 200 markdown" do
    note = create_note(studio: @studio, created_by: @user, title: "Test note")
    post "/studios/#{@studio.handle}/n/#{note.truncated_id}/actions/add_comment",
      params: { text: "This is a test comment" }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Verify comment was created
    assert note.comments.exists?, "Comment should have been created on note"
  end

  test "POST add_comment action on decision returns 200 markdown" do
    decision = create_decision(studio: @studio, created_by: @user, question: "Test decision?")
    post "/studios/#{@studio.handle}/d/#{decision.truncated_id}/actions/add_comment",
      params: { text: "This is a test comment" }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Verify comment was created
    assert decision.comments.exists?, "Comment should have been created on decision"
  end

  test "POST add_comment action on commitment returns 200 markdown" do
    commitment = create_commitment(studio: @studio, created_by: @user, title: "Test commitment")
    post "/studios/#{@studio.handle}/c/#{commitment.truncated_id}/actions/add_comment",
      params: { text: "This is a test comment" }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Verify comment was created
    assert commitment.comments.exists?, "Comment should have been created on commitment"
  end

  # Conditional action display tests
  test "commitment show page shows join_commitment action when user has not joined" do
    commitment = create_commitment(studio: @studio, created_by: @user, title: "Test commitment")

    get "/studios/#{@studio.handle}/c/#{commitment.truncated_id}", headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    assert response.body.include?("`join_commitment()`"),
      "Should show join_commitment action when user hasn't joined"
  end

  test "commitment show page hides join_commitment action when user has already joined" do
    commitment = create_commitment(studio: @studio, created_by: @user, title: "Test commitment")

    # Join the commitment
    participant = CommitmentParticipant.find_or_create_by!(
      commitment: commitment,
      user: @user,
      tenant: @tenant,
    )
    participant.update!(committed: true, committed_at: Time.current)

    get "/studios/#{@studio.handle}/c/#{commitment.truncated_id}", headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    refute response.body.include?("`join_commitment()`"),
      "Should NOT show join_commitment action when user has already joined"
    # Should still show add_comment
    assert response.body.include?("`add_comment(text)`"),
      "Should still show add_comment action"
  end

  test "commitment show page hides join_commitment action when commitment is closed" do
    commitment = create_commitment(studio: @studio, created_by: @user, title: "Test commitment")
    commitment.update!(deadline: 1.day.ago) # closed? checks if deadline < Time.now

    get "/studios/#{@studio.handle}/c/#{commitment.truncated_id}", headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    refute response.body.include?("`join_commitment()`"),
      "Should NOT show join_commitment action when commitment is closed"
  end

  test "note show page shows confirm_read action when user has not confirmed" do
    note = create_note(studio: @studio, created_by: @user, title: "Test note")

    get "/studios/#{@studio.handle}/n/#{note.truncated_id}", headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    assert response.body.include?("`confirm_read()`"),
      "Should show confirm_read action when user hasn't confirmed"
    assert response.body.include?("to confirm that you have read this note"),
      "Should show 'confirm' message for unconfirmed notes"
  end

  test "note show page hides confirm_read action when user has confirmed" do
    note = create_note(studio: @studio, created_by: @user, title: "Test note")

    # Confirm read by creating a history event
    NoteHistoryEvent.create!(
      tenant: @tenant,
      note: note,
      user: @user,
      event_type: 'read_confirmation',
      happened_at: Time.current,
    )

    get "/studios/#{@studio.handle}/n/#{note.truncated_id}", headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    assert response.body.include?("You have confirmed that you have read this note"),
      "Should show confirmation message"
    # Should still show add_comment
    assert response.body.include?("`add_comment(text)`"),
      "Should still show add_comment action"
  end

  test "note show page shows reconfirm action when note updated after confirmation" do
    note = create_note(studio: @studio, created_by: @user, title: "Test note")

    # Confirm read by creating a history event in the past
    NoteHistoryEvent.create!(
      tenant: @tenant,
      note: note,
      user: @user,
      event_type: 'read_confirmation',
      happened_at: 1.hour.ago,
    )

    # Update note after confirmation
    note.update!(updated_at: Time.current)

    get "/studios/#{@studio.handle}/n/#{note.truncated_id}", headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    assert response.body.include?("`confirm_read()`"),
      "Should show confirm_read action when note updated since confirmation"
    assert response.body.include?("reconfirm"),
      "Should mention reconfirm when note was updated"
  end
end