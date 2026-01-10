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
    response.body.include?("# Actions") || response.body.include?("# [Actions]")
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

  test "GET /studios/:studio_handle/commit returns 200 markdown with actions" do
    assert_200_markdown_page_with_actions("Commit", "/studios/#{@studio.handle}/commit")
  end

  test "GET /studios/:studio_handle/n/:note_id returns 200 markdown with actions" do
    note = create_note(studio: @studio, created_by: @user, title: "Test note")
    assert_200_markdown_page_with_actions(note.title, "/studios/#{@studio.handle}/n/#{note.truncated_id}")
  end

  test "GET /studios/:studio_handle/n/:note_id/edit returns 200 markdown with actions" do
    note = create_note(studio: @studio, created_by: @user, title: "Test note")
    assert_200_markdown_page_with_actions("Edit Note", "/studios/#{@studio.handle}/n/#{note.truncated_id}/edit")
  end

  test "GET /studios/:studio_handle/d/:decision_id returns 200 markdown with actions" do
    decision = create_decision(studio: @studio, created_by: @user, question: "Test decision?")
    assert_200_markdown_page_with_actions(decision.question, "/studios/#{@studio.handle}/d/#{decision.truncated_id}")
  end

  test "GET /studios/:studio_handle/c/:commitment_id returns 200 markdown with actions" do
    commitment = create_commitment(studio: @studio, created_by: @user, title: "Test commitment")
    assert_200_markdown_page_with_actions(commitment.title, "/studios/#{@studio.handle}/c/#{commitment.truncated_id}")
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

  # Studio actions
  test "POST create_studio action creates studio and returns 200 markdown" do
    handle = "test-studio-#{SecureRandom.hex(4)}"
    post "/studios/new/actions/create_studio",
      params: {
        name: "Test Studio",
        handle: handle,
        description: "A test studio",
        timezone: "America/New_York",
        tempo: "daily",
        synchronization_mode: "improv",
      }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Verify studio was created
    studio = Studio.find_by(handle: handle)
    assert studio, "Studio should have been created"
    assert_equal "Test Studio", studio.name
  end

  # Note actions
  test "POST create_note action creates note and returns 200 markdown" do
    note_count_before = Note.count
    post "/studios/#{@studio.handle}/note/actions/create_note",
      params: { text: "This is a test note" }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Verify note was created
    assert_equal note_count_before + 1, Note.count, "Note should have been created"
    assert Note.exists?(text: "This is a test note"), "Note should have the correct text"
  end

  test "POST confirm_read action creates read confirmation and returns 200 markdown" do
    note = create_note(studio: @studio, created_by: @user, title: "Test note")
    post "/studios/#{@studio.handle}/n/#{note.truncated_id}/actions/confirm_read",
      params: {}.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Verify read confirmation was created
    assert NoteHistoryEvent.exists?(note: note, user: @user, event_type: 'read_confirmation'),
      "Read confirmation event should have been created"
  end

  test "POST update_note action updates note and returns 200 markdown" do
    note = create_note(studio: @studio, created_by: @user, title: "Test note", text: "Original text")
    post "/studios/#{@studio.handle}/n/#{note.truncated_id}/edit/actions/update_note",
      params: { text: "Updated note text" }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Verify note was updated
    note.reload
    assert_equal "Updated note text", note.text, "Note text should have been updated"
  end

  # Decision actions
  test "POST create_decision action creates decision and returns 200 markdown" do
    decision_count_before = Decision.count
    post "/studios/#{@studio.handle}/decide/actions/create_decision",
      params: {
        question: "Test decision question?",
        description: "A test decision",
        options_open: true,
        deadline: 1.week.from_now.to_date.to_s,
      }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Verify decision was created
    assert_equal decision_count_before + 1, Decision.count, "Decision should have been created"
    assert Decision.exists?(question: "Test decision question?"), "Decision should have the correct question"
  end

  test "POST add_option action adds option to decision and returns 200 markdown" do
    decision = create_decision(studio: @studio, created_by: @user, question: "Test decision?")
    options_count_before = decision.options.count
    post "/studios/#{@studio.handle}/d/#{decision.truncated_id}/actions/add_option",
      params: { title: "Test option" }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Verify option was added
    decision.reload
    assert_equal options_count_before + 1, decision.options.count, "Option should have been added"
    assert decision.options.exists?(title: "Test option"), "Option should have the correct title"
  end

  test "POST vote action records vote and returns 200 markdown" do
    decision = create_decision(studio: @studio, created_by: @user, question: "Test decision?")
    # First add an option to vote on
    option = create_option(decision: decision, title: "Option A")

    post "/studios/#{@studio.handle}/d/#{decision.truncated_id}/actions/vote",
      params: { option_title: "Option A", accept: true, prefer: false }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Verify vote was recorded (votes belong to decision_participant, not user directly)
    option.reload
    vote = option.votes.joins(:decision_participant).find_by(decision_participants: { user_id: @user.id })
    assert vote, "Vote should have been recorded"
    assert_equal 1, vote.accepted, "Vote should be marked as accepted"
    assert_equal 0, vote.preferred, "Vote should not be marked as preferred"
  end

  # Commitment actions
  test "POST create_commitment action creates commitment and returns 200 markdown" do
    commitment_count_before = Commitment.count
    post "/studios/#{@studio.handle}/commit/actions/create_commitment",
      params: {
        title: "Test commitment",
        description: "A test commitment",
        critical_mass: 2,
        deadline: 1.week.from_now.to_date.to_s,
      }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Verify commitment was created
    assert_equal commitment_count_before + 1, Commitment.count, "Commitment should have been created"
    assert Commitment.exists?(title: "Test commitment"), "Commitment should have the correct title"
  end

  test "POST join_commitment action joins user to commitment and returns 200 markdown" do
    commitment = create_commitment(studio: @studio, created_by: @user, title: "Test commitment")
    post "/studios/#{@studio.handle}/c/#{commitment.truncated_id}/actions/join_commitment",
      params: {}.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Verify user joined commitment
    participant = CommitmentParticipant.find_by(commitment: commitment, user: @user)
    assert participant, "User should have joined the commitment"
    assert participant.committed, "Participant should be marked as committed"
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

  # Settings action tests
  test "POST update_studio_settings action updates studio and returns 200 markdown" do
    # Make user an admin for this test
    studio_user = @user.studio_users.find_by(studio: @studio)
    studio_user.add_role!('admin')

    post "/studios/#{@studio.handle}/settings/actions/update_studio_settings",
      params: {
        name: "Updated Studio Name",
        description: "Updated description",
      }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Verify studio was updated
    @studio.reload
    assert_equal "Updated Studio Name", @studio.name, "Studio name should have been updated"
    assert_equal "Updated description", @studio.description, "Studio description should have been updated"
  ensure
    # Restore original name
    @studio.update!(name: "Global Studio", description: nil)
    studio_user&.remove_role!('admin')
  end

  test "POST update_decision_settings action updates decision and returns 200 markdown" do
    decision = create_decision(studio: @studio, created_by: @user, question: "Original question?")
    post "/studios/#{@studio.handle}/d/#{decision.truncated_id}/settings/actions/update_decision_settings",
      params: {
        question: "Updated question?",
        description: "Updated description",
      }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Verify decision was updated
    decision.reload
    assert_equal "Updated question?", decision.question, "Decision question should have been updated"
    assert_equal "Updated description", decision.description, "Decision description should have been updated"
  end

  test "POST update_commitment_settings action updates commitment and returns 200 markdown" do
    commitment = create_commitment(studio: @studio, created_by: @user, title: "Original title")
    post "/studios/#{@studio.handle}/c/#{commitment.truncated_id}/settings/actions/update_commitment_settings",
      params: {
        title: "Updated title",
        description: "Updated description",
      }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Verify commitment was updated
    commitment.reload
    assert_equal "Updated title", commitment.title, "Commitment title should have been updated"
    assert_equal "Updated description", commitment.description, "Commitment description should have been updated"
  end

  test "POST join_studio action joins scene and returns 200 markdown" do
    # Create a scene (open studio) that allows direct join
    scene = Studio.create!(
      tenant: @tenant,
      name: "Test Scene",
      handle: "test-scene-#{SecureRandom.hex(4)}",
      studio_type: 'scene',
      open_scene: true,
      created_by: @user,
    )
    scene.add_user!(@user, roles: ['admin'])
    scene.enable_api!

    # Create a different user who will join
    other_user = User.create!(
      name: "Other User",
      email: "other-#{SecureRandom.hex(4)}@test.com",
    )
    @tenant.add_user!(other_user)
    other_token = ApiToken.create!(
      tenant: @tenant,
      user: other_user,
      scopes: ApiToken.valid_scopes,
    )
    other_headers = {
      "Authorization" => "Bearer #{other_token.token}",
      "Accept" => "text/markdown",
      "Content-Type" => "application/json",
    }

    post "/scenes/#{scene.handle}/join/actions/join_studio",
      params: {}.to_json,
      headers: other_headers
    assert_equal 200, response.status
    assert is_markdown?

    # Verify user joined the scene
    other_user.reload
    assert other_user.studios.include?(scene), "User should have joined the scene"
  ensure
    StudioUser.where(studio: scene).delete_all if scene
    scene&.destroy
    TenantUser.where(user: other_user).delete_all if other_user
    other_token&.destroy
    other_user&.destroy
  end
end