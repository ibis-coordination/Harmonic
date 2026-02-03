require "test_helper"

class MarkdownUiTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @superagent = @global_superagent
    @superagent.enable_api!
    @user = @global_user
    @api_token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.valid_scopes,
    )
    @plaintext_token = @api_token.plaintext_token
    @headers = {
      "Authorization" => "Bearer #{@plaintext_token}",
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
    assert_200_markdown_page_with_actions(@superagent.name, "/studios/#{@superagent.handle}")
  end

  test "GET /studios/:studio_handle/note returns 200 markdown with actions" do
    assert_200_markdown_page_with_actions("Note", "/studios/#{@superagent.handle}/note")
  end

  test "GET /studios/:studio_handle/decide returns 200 markdown with actions" do
    assert_200_markdown_page_with_actions("Decide", "/studios/#{@superagent.handle}/decide")
  end

  test "GET /studios/:studio_handle/commit returns 200 markdown with actions" do
    assert_200_markdown_page_with_actions("Commit", "/studios/#{@superagent.handle}/commit")
  end

  test "GET /studios/:studio_handle/n/:note_id returns 200 markdown with actions" do
    note = create_note(superagent: @superagent, created_by: @user, title: "Test note")
    assert_200_markdown_page_with_actions(note.title, "/studios/#{@superagent.handle}/n/#{note.truncated_id}")
  end

  test "GET /studios/:studio_handle/n/:note_id/edit returns 200 markdown with actions" do
    note = create_note(superagent: @superagent, created_by: @user, title: "Test note")
    assert_200_markdown_page_with_actions("Edit Note", "/studios/#{@superagent.handle}/n/#{note.truncated_id}/edit")
  end

  test "GET /studios/:studio_handle/d/:decision_id returns 200 markdown with actions" do
    decision = create_decision(superagent: @superagent, created_by: @user, question: "Test decision?")
    assert_200_markdown_page_with_actions(decision.question, "/studios/#{@superagent.handle}/d/#{decision.truncated_id}")
  end

  test "GET /studios/:studio_handle/c/:commitment_id returns 200 markdown with actions" do
    commitment = create_commitment(superagent: @superagent, created_by: @user, title: "Test commitment")
    assert_200_markdown_page_with_actions(commitment.title, "/studios/#{@superagent.handle}/c/#{commitment.truncated_id}")
  end

  # Cycle detail pages
  test "GET /studios/:studio_handle/cycles returns 200 markdown" do
    get "/studios/#{@superagent.handle}/cycles", headers: @headers
    assert_equal 200, response.status
    assert is_markdown?
  end

  test "GET /studios/:studio_handle/cycles/today returns 200 markdown" do
    get "/studios/#{@superagent.handle}/cycles/today", headers: @headers
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
    superagent = Superagent.find_by(handle: handle)
    assert superagent, "Studio should have been created"
    assert_equal "Test Studio", superagent.name
  end

  # Note actions
  test "POST create_note action creates note and returns 200 markdown" do
    note_count_before = Note.count
    post "/studios/#{@superagent.handle}/note/actions/create_note",
      params: { text: "This is a test note" }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Verify note was created
    assert_equal note_count_before + 1, Note.count, "Note should have been created"
    assert Note.exists?(text: "This is a test note"), "Note should have the correct text"
  end

  test "POST confirm_read action creates read confirmation and returns 200 markdown" do
    note = create_note(superagent: @superagent, created_by: @user, title: "Test note")
    post "/studios/#{@superagent.handle}/n/#{note.truncated_id}/actions/confirm_read",
      params: {}.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Verify read confirmation was created
    assert NoteHistoryEvent.exists?(note: note, user: @user, event_type: 'read_confirmation'),
      "Read confirmation event should have been created"
  end

  test "POST update_note action updates note and returns 200 markdown" do
    note = create_note(superagent: @superagent, created_by: @user, title: "Test note", text: "Original text")
    post "/studios/#{@superagent.handle}/n/#{note.truncated_id}/edit/actions/update_note",
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
    post "/studios/#{@superagent.handle}/decide/actions/create_decision",
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
    decision = create_decision(superagent: @superagent, created_by: @user, question: "Test decision?")
    options_count_before = decision.options.count
    post "/studios/#{@superagent.handle}/d/#{decision.truncated_id}/actions/add_option",
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
    decision = create_decision(superagent: @superagent, created_by: @user, question: "Test decision?")
    # First add an option to vote on
    option = create_option(decision: decision, title: "Option A")

    post "/studios/#{@superagent.handle}/d/#{decision.truncated_id}/actions/vote",
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
    post "/studios/#{@superagent.handle}/commit/actions/create_commitment",
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
    commitment = create_commitment(superagent: @superagent, created_by: @user, title: "Test commitment")
    post "/studios/#{@superagent.handle}/c/#{commitment.truncated_id}/actions/join_commitment",
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
    Heartbeat.where(superagent: @superagent, user: @user).delete_all

    get "/studios/#{@superagent.handle}", headers: @headers
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
      superagent: @superagent,
      user: @user,
      expires_at: 1.day.from_now,
    )

    get "/studios/#{@superagent.handle}", headers: @headers
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
    Heartbeat.where(superagent: @superagent, user: @user).delete_all

    post "/studios/#{@superagent.handle}/actions/send_heartbeat",
      params: {}.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Verify heartbeat was created
    assert Heartbeat.where(superagent: @superagent, user: @user).exists?,
      "Heartbeat should have been created"
  ensure
    Heartbeat.where(superagent: @superagent, user: @user).delete_all
  end

  test "send_heartbeat action appears in frontmatter when no heartbeat exists" do
    # Ensure no heartbeat exists for this cycle
    Heartbeat.where(superagent: @superagent, user: @user).delete_all

    get "/studios/#{@superagent.handle}", headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Extract frontmatter (between first two ---)
    frontmatter = response.body.split("---")[1]
    assert frontmatter, "Response should have frontmatter"

    # Verify send_heartbeat action is in the frontmatter
    assert frontmatter.include?("- name: send_heartbeat"),
      "Frontmatter should include send_heartbeat action when no heartbeat exists"
  ensure
    Heartbeat.where(superagent: @superagent, user: @user).delete_all
  end

  test "send_heartbeat action does not appear in frontmatter when heartbeat exists" do
    # Create a heartbeat for the current cycle
    heartbeat = Heartbeat.create!(
      tenant: @tenant,
      superagent: @superagent,
      user: @user,
      expires_at: 1.day.from_now,
    )

    get "/studios/#{@superagent.handle}", headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Extract frontmatter (between first two ---)
    frontmatter = response.body.split("---")[1]
    assert frontmatter, "Response should have frontmatter"

    # Verify send_heartbeat action is NOT in the frontmatter
    refute frontmatter.include?("- name: send_heartbeat"),
      "Frontmatter should NOT include send_heartbeat action when heartbeat exists"
  ensure
    heartbeat&.destroy
  end

  test "studio actions index shows send_heartbeat when no heartbeat exists" do
    # Ensure no heartbeat exists for this cycle
    Heartbeat.where(superagent: @superagent, user: @user).delete_all

    get "/studios/#{@superagent.handle}/actions", headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Should include the send_heartbeat action
    assert response.body.include?("send_heartbeat"),
      "Actions index should include send_heartbeat action when no heartbeat exists"
  ensure
    Heartbeat.where(superagent: @superagent, user: @user).delete_all
  end

  test "studio actions index does not show send_heartbeat when heartbeat exists" do
    # Create a heartbeat for the current cycle
    heartbeat = Heartbeat.create!(
      tenant: @tenant,
      superagent: @superagent,
      user: @user,
      expires_at: 1.day.from_now,
    )

    get "/studios/#{@superagent.handle}/actions", headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Should NOT include the send_heartbeat action
    refute response.body.include?("send_heartbeat"),
      "Actions index should NOT include send_heartbeat action when heartbeat exists"
  ensure
    heartbeat&.destroy
  end

  # add_comment action tests
  test "POST add_comment action on note returns 200 markdown" do
    note = create_note(superagent: @superagent, created_by: @user, title: "Test note")
    post "/studios/#{@superagent.handle}/n/#{note.truncated_id}/actions/add_comment",
      params: { text: "This is a test comment" }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Verify comment was created
    assert note.comments.exists?, "Comment should have been created on note"
  end

  test "POST add_comment action on decision returns 200 markdown" do
    decision = create_decision(superagent: @superagent, created_by: @user, question: "Test decision?")
    post "/studios/#{@superagent.handle}/d/#{decision.truncated_id}/actions/add_comment",
      params: { text: "This is a test comment" }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Verify comment was created
    assert decision.comments.exists?, "Comment should have been created on decision"
  end

  test "POST add_comment action on commitment returns 200 markdown" do
    commitment = create_commitment(superagent: @superagent, created_by: @user, title: "Test commitment")
    post "/studios/#{@superagent.handle}/c/#{commitment.truncated_id}/actions/add_comment",
      params: { text: "This is a test comment" }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Verify comment was created
    assert commitment.comments.exists?, "Comment should have been created on commitment"
  end

  # Conditional action display tests
  test "commitment show page shows join_commitment action when user has not joined" do
    commitment = create_commitment(superagent: @superagent, created_by: @user, title: "Test commitment")

    get "/studios/#{@superagent.handle}/c/#{commitment.truncated_id}", headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    assert response.body.include?("`join_commitment()`"),
      "Should show join_commitment action when user hasn't joined"
  end

  test "commitment show page hides join_commitment action when user has already joined" do
    commitment = create_commitment(superagent: @superagent, created_by: @user, title: "Test commitment")

    # Join the commitment
    participant = CommitmentParticipant.find_or_create_by!(
      commitment: commitment,
      user: @user,
      tenant: @tenant,
    )
    participant.update!(committed: true, committed_at: Time.current)

    get "/studios/#{@superagent.handle}/c/#{commitment.truncated_id}", headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    refute response.body.include?("`join_commitment()`"),
      "Should NOT show join_commitment action when user has already joined"
    # Should still show add_comment
    assert response.body.include?("`add_comment(text)`"),
      "Should still show add_comment action"
  end

  test "commitment show page hides join_commitment action when commitment is closed" do
    commitment = create_commitment(superagent: @superagent, created_by: @user, title: "Test commitment")
    commitment.update!(deadline: 1.day.ago) # closed? checks if deadline < Time.now

    get "/studios/#{@superagent.handle}/c/#{commitment.truncated_id}", headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    refute response.body.include?("`join_commitment()`"),
      "Should NOT show join_commitment action when commitment is closed"
  end

  test "note show page shows confirm_read action when user has not confirmed" do
    note = create_note(superagent: @superagent, created_by: @user, title: "Test note")

    get "/studios/#{@superagent.handle}/n/#{note.truncated_id}", headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    assert response.body.include?("`confirm_read()`"),
      "Should show confirm_read action when user hasn't confirmed"
    assert response.body.include?("to confirm that you have read this note"),
      "Should show 'confirm' message for unconfirmed notes"
  end

  test "note show page hides confirm_read action when user has confirmed" do
    note = create_note(superagent: @superagent, created_by: @user, title: "Test note")

    # Confirm read by creating a history event
    NoteHistoryEvent.create!(
      tenant: @tenant,
      note: note,
      user: @user,
      event_type: 'read_confirmation',
      happened_at: Time.current,
    )

    get "/studios/#{@superagent.handle}/n/#{note.truncated_id}", headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    assert response.body.include?("You have confirmed that you have read this note"),
      "Should show confirmation message"
    # Should still show add_comment
    assert response.body.include?("`add_comment(text)`"),
      "Should still show add_comment action"
  end

  test "note show page shows reconfirm action when note updated after confirmation" do
    note = create_note(superagent: @superagent, created_by: @user, title: "Test note")

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

    get "/studios/#{@superagent.handle}/n/#{note.truncated_id}", headers: @headers
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
    superagent_member = @user.superagent_members.find_by(superagent: @superagent)
    superagent_member.add_role!('admin')

    post "/studios/#{@superagent.handle}/settings/actions/update_studio_settings",
      params: {
        name: "Updated Studio Name",
        description: "Updated description",
      }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Verify studio was updated
    @superagent.reload
    assert_equal "Updated Studio Name", @superagent.name, "Studio name should have been updated"
    assert_equal "Updated description", @superagent.description, "Studio description should have been updated"
  ensure
    # Restore original name
    @superagent.update!(name: "Global Studio", description: nil)
    superagent_member&.remove_role!('admin')
  end

  test "POST update_studio_settings action with invitations param updates setting" do
    superagent_member = @user.superagent_members.find_by(superagent: @superagent)
    superagent_member.add_role!('admin')

    # Set initial value
    @superagent.settings['all_members_can_invite'] = false
    @superagent.save!

    post "/studios/#{@superagent.handle}/settings/actions/update_studio_settings",
      params: { invitations: "all_members" }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    @superagent.reload
    assert @superagent.all_members_can_invite?, "Studio should have all_members_can_invite enabled"
  ensure
    superagent_member&.remove_role!('admin')
  end

  test "POST update_studio_settings action with representation param updates setting" do
    superagent_member = @user.superagent_members.find_by(superagent: @superagent)
    superagent_member.add_role!('admin')

    # Set initial value
    @superagent.settings['any_member_can_represent'] = false
    @superagent.save!

    post "/studios/#{@superagent.handle}/settings/actions/update_studio_settings",
      params: { representation: "any_member" }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    @superagent.reload
    assert @superagent.any_member_can_represent?, "Studio should have any_member_can_represent enabled"
  ensure
    superagent_member&.remove_role!('admin')
  end

  test "POST update_studio_settings action with file_uploads param updates setting" do
    superagent_member = @user.superagent_members.find_by(superagent: @superagent)
    superagent_member.add_role!('admin')

    # Set initial value
    @superagent.settings['allow_file_uploads'] = false
    @superagent.save!

    post "/studios/#{@superagent.handle}/settings/actions/update_studio_settings",
      params: { file_uploads: true }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    @superagent.reload
    assert @superagent.allow_file_uploads?, "Studio should have file uploads enabled"
  ensure
    superagent_member&.remove_role!('admin')
  end

  test "POST update_studio_settings action with api_enabled=true param enables API" do
    superagent_member = @user.superagent_members.find_by(superagent: @superagent)
    superagent_member.add_role!('admin')

    # Studio already has API enabled in setup, but verify setting api_enabled=true works
    post "/studios/#{@superagent.handle}/settings/actions/update_studio_settings",
      params: { api_enabled: true }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    @superagent.reload
    assert @superagent.feature_enabled?('api'), "Studio should have API enabled"
  ensure
    superagent_member&.remove_role!('admin')
  end

  test "POST update_decision_settings action updates decision and returns 200 markdown" do
    decision = create_decision(superagent: @superagent, created_by: @user, question: "Original question?")
    post "/studios/#{@superagent.handle}/d/#{decision.truncated_id}/settings/actions/update_decision_settings",
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
    commitment = create_commitment(superagent: @superagent, created_by: @user, title: "Original title")
    post "/studios/#{@superagent.handle}/c/#{commitment.truncated_id}/settings/actions/update_commitment_settings",
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

  # HTML entities should not appear in markdown output
  test "note with apostrophe in title should not have HTML entities in markdown" do
    note = create_note(superagent: @superagent, created_by: @user, title: "Test's apostrophe note")
    get "/studios/#{@superagent.handle}/n/#{note.truncated_id}", headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Should contain the actual apostrophe, not HTML entity
    assert_match(/Test's apostrophe/, response.body, "Title should contain actual apostrophe, not HTML entity")
    refute_match(/&#39;/, response.body, "Markdown output should not contain HTML entities like &#39;")
    refute_match(/&amp;/, response.body, "Markdown output should not contain HTML entities like &amp;")
  end

  # Learn pages should return markdown, not HTML
  test "GET /learn returns proper markdown without HTML tags" do
    get "/learn", headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Should NOT contain HTML tags
    refute_match(/<h1>/, response.body, "Learn page should not contain <h1> HTML tags")
    refute_match(/<ul>/, response.body, "Learn page should not contain <ul> HTML tags")
    refute_match(/<li>/, response.body, "Learn page should not contain <li> HTML tags")
    refute_match(/<a /, response.body, "Learn page should not contain <a> HTML tags")

    # Should contain markdown syntax
    assert_match(/^# Learn/, response.body, "Learn page should have markdown heading")
    assert_match(/^\* \[/, response.body, "Learn page should have markdown list items with links")
  end

  # Error page tests - should return markdown, not 500
  test "GET note edit without permission returns 403 markdown" do
    # Create a note by a different user
    other_user = User.create!(name: "Other", email: "other-#{SecureRandom.hex(4)}@test.com")
    @tenant.add_user!(other_user)
    @superagent.add_user!(other_user)
    note = create_note(superagent: @superagent, created_by: other_user, title: "Not my note")

    get "/studios/#{@superagent.handle}/n/#{note.truncated_id}/edit", headers: @headers
    assert_equal 403, response.status
    assert response.content_type.starts_with?("text/markdown"), "403 page should return markdown format"
    assert_match(/403 Forbidden/, response.body, "Should show 403 message")
  ensure
    SuperagentMember.where(user: other_user).delete_all if other_user
    TenantUser.where(user: other_user).delete_all if other_user
    note&.destroy
    other_user&.destroy
  end

  # User profile page tests
  test "GET /u/:handle returns 200 markdown for user profile" do
    get "/u/#{@user.handle}", headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Should contain user info
    assert_match(/#{@user.display_name}/, response.body, "Should show user's display name")
  end

  test "POST join_studio action joins scene and returns 200 markdown" do
    # Create a scene (open studio) that allows direct join
    scene = Superagent.create!(
      tenant: @tenant,
      name: "Test Scene",
      handle: "test-scene-#{SecureRandom.hex(4)}",
      superagent_type: 'scene',
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
      "Authorization" => "Bearer #{other_token.plaintext_token}",
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
    assert other_user.superagents.include?(scene), "User should have joined the scene"
  ensure
    SuperagentMember.where(superagent: scene).delete_all if scene
    scene&.destroy
    TenantUser.where(user: other_user).delete_all if other_user
    other_token&.destroy
    other_user&.destroy
  end

  # === Pin/Unpin Action Tests ===

  test "GET note settings returns 200 markdown" do
    note = create_note(superagent: @superagent, created_by: @user, title: "Test Note")
    get "/studios/#{@superagent.handle}/n/#{note.truncated_id}/settings", headers: @headers
    assert_equal 200, response.status
    assert is_markdown?
    assert_match(/Note Settings/, response.body, "Should show note settings heading")
    assert_match(/pin_note/, response.body, "Should show pin_note action")
  end

  test "POST pin_note action pins note and returns 200 markdown" do
    note = create_note(superagent: @superagent, created_by: @user, title: "Pinnable Note")
    refute note.is_pinned?(tenant: @tenant, superagent: @superagent, user: @user), "Note should not be pinned initially"

    post "/studios/#{@superagent.handle}/n/#{note.truncated_id}/settings/actions/pin_note",
      params: {}.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    @superagent.reload
    assert note.is_pinned?(tenant: @tenant, superagent: @superagent, user: @user), "Note should be pinned after action"
  end

  test "POST unpin_note action unpins note and returns 200 markdown" do
    note = create_note(superagent: @superagent, created_by: @user, title: "Pinned Note")
    note.pin!(tenant: @tenant, superagent: @superagent, user: @user)
    assert note.is_pinned?(tenant: @tenant, superagent: @superagent, user: @user), "Note should be pinned initially"

    post "/studios/#{@superagent.handle}/n/#{note.truncated_id}/settings/actions/unpin_note",
      params: {}.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    @superagent.reload
    refute note.is_pinned?(tenant: @tenant, superagent: @superagent, user: @user), "Note should be unpinned after action"
  end

  test "POST pin_decision action pins decision and returns 200 markdown" do
    decision = create_decision(superagent: @superagent, created_by: @user, question: "Pinnable Decision?")
    refute decision.is_pinned?(tenant: @tenant, superagent: @superagent, user: @user), "Decision should not be pinned initially"

    post "/studios/#{@superagent.handle}/d/#{decision.truncated_id}/settings/actions/pin_decision",
      params: {}.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    @superagent.reload
    assert decision.is_pinned?(tenant: @tenant, superagent: @superagent, user: @user), "Decision should be pinned after action"
  end

  test "POST unpin_decision action unpins decision and returns 200 markdown" do
    decision = create_decision(superagent: @superagent, created_by: @user, question: "Pinned Decision?")
    decision.pin!(tenant: @tenant, superagent: @superagent, user: @user)
    assert decision.is_pinned?(tenant: @tenant, superagent: @superagent, user: @user), "Decision should be pinned initially"

    post "/studios/#{@superagent.handle}/d/#{decision.truncated_id}/settings/actions/unpin_decision",
      params: {}.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    @superagent.reload
    refute decision.is_pinned?(tenant: @tenant, superagent: @superagent, user: @user), "Decision should be unpinned after action"
  end

  test "POST pin_commitment action pins commitment and returns 200 markdown" do
    commitment = create_commitment(superagent: @superagent, created_by: @user, title: "Pinnable Commitment")
    refute commitment.is_pinned?(tenant: @tenant, superagent: @superagent, user: @user), "Commitment should not be pinned initially"

    post "/studios/#{@superagent.handle}/c/#{commitment.truncated_id}/settings/actions/pin_commitment",
      params: {}.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    @superagent.reload
    assert commitment.is_pinned?(tenant: @tenant, superagent: @superagent, user: @user), "Commitment should be pinned after action"
  end

  test "POST unpin_commitment action unpins commitment and returns 200 markdown" do
    commitment = create_commitment(superagent: @superagent, created_by: @user, title: "Pinned Commitment")
    commitment.pin!(tenant: @tenant, superagent: @superagent, user: @user)
    assert commitment.is_pinned?(tenant: @tenant, superagent: @superagent, user: @user), "Commitment should be pinned initially"

    post "/studios/#{@superagent.handle}/c/#{commitment.truncated_id}/settings/actions/unpin_commitment",
      params: {}.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    @superagent.reload
    refute commitment.is_pinned?(tenant: @tenant, superagent: @superagent, user: @user), "Commitment should be unpinned after action"
  end

  # === Create Studio with Optional Settings ===

  test "POST create_studio with api_enabled param creates studio with API enabled" do
    handle = "api-studio-#{SecureRandom.hex(4)}"
    post "/studios/new/actions/create_studio",
      params: {
        name: "API Enabled Studio",
        handle: handle,
        description: "A studio with API enabled",
        timezone: "America/New_York",
        tempo: "daily",
        synchronization_mode: "improv",
        api_enabled: true,
      }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    superagent = Superagent.find_by(handle: handle)
    assert superagent, "Studio should have been created"
    assert superagent.api_enabled?, "Studio should have API enabled"
  end

  test "POST create_studio with invitations param creates studio with correct setting" do
    handle = "invitations-studio-#{SecureRandom.hex(4)}"
    post "/studios/new/actions/create_studio",
      params: {
        name: "Invitations Studio",
        handle: handle,
        timezone: "UTC",
        tempo: "daily",
        synchronization_mode: "improv",
        invitations: "only_admins",
      }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    superagent = Superagent.find_by(handle: handle)
    assert superagent, "Studio should have been created"
    refute superagent.all_members_can_invite?, "Studio should have only_admins can invite"
  end

  test "POST create_studio with representation param creates studio with correct setting" do
    handle = "representation-studio-#{SecureRandom.hex(4)}"
    post "/studios/new/actions/create_studio",
      params: {
        name: "Representation Studio",
        handle: handle,
        timezone: "UTC",
        tempo: "daily",
        synchronization_mode: "improv",
        representation: "only_representatives",
      }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    superagent = Superagent.find_by(handle: handle)
    assert superagent, "Studio should have been created"
    refute superagent.any_member_can_represent?, "Studio should have only_representatives setting"
  end

  test "POST create_studio with file_uploads param creates studio with correct setting" do
    handle = "uploads-studio-#{SecureRandom.hex(4)}"
    post "/studios/new/actions/create_studio",
      params: {
        name: "Uploads Studio",
        handle: handle,
        timezone: "UTC",
        tempo: "daily",
        synchronization_mode: "improv",
        file_uploads: true,
      }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    superagent = Superagent.find_by(handle: handle)
    assert superagent, "Studio should have been created"
    assert superagent.allow_file_uploads?, "Studio should have file uploads enabled"
  end

  # === API Protection: api_enabled not changeable via API ===

  test "POST update_studio_settings ignores api_enabled param entirely" do
    superagent_member = @user.superagent_members.find_by(superagent: @superagent)
    superagent_member.add_role!('admin')

    # Ensure API is enabled first
    @superagent.settings['feature_flags'] ||= {}
    @superagent.settings['feature_flags']['api'] = true
    @superagent.save!
    assert @superagent.api_enabled?, "Studio should have API enabled initially"

    # api_enabled param should be ignored entirely (can't change via API)
    # Try to disable - should be ignored
    post "/studios/#{@superagent.handle}/settings/actions/update_studio_settings",
      params: { api_enabled: false }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    @superagent.reload
    assert @superagent.api_enabled?, "api_enabled=false should be ignored - setting unchanged"

    # Try to enable (already enabled) - should also be ignored (no-op)
    post "/studios/#{@superagent.handle}/settings/actions/update_studio_settings",
      params: { api_enabled: true }.to_json,
      headers: @headers
    assert_equal 200, response.status

    @superagent.reload
    assert @superagent.api_enabled?, "api_enabled=true should be ignored - setting unchanged"
  ensure
    superagent_member&.remove_role!('admin')
  end

  # === Phase 2: User Management Actions ===

  test "GET /u/:handle/settings returns 200 markdown with actions section" do
    get "/u/#{@user.handle}/settings", headers: @headers
    assert_equal 200, response.status
    assert is_markdown?
    assert has_actions_section?, "User settings should have actions section"
    assert_match(/update_profile/, response.body, "Should show update_profile action")
  end

  test "POST update_profile action updates user name and returns 200 markdown" do
    original_name = @user.name
    post "/u/#{@user.handle}/settings/actions/update_profile",
      params: { name: "Updated Name" }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    @user.reload
    assert_equal "Updated Name", @user.name, "User name should have been updated"
  ensure
    @user.update!(name: original_name)
    TenantUser.unscoped.where(user: @user).update_all(display_name: original_name)
  end

  test "POST update_profile action updates user handle and returns 200 markdown" do
    original_handle = @user.handle
    new_handle = "updated-#{SecureRandom.hex(4)}"
    post "/u/#{@user.handle}/settings/actions/update_profile",
      params: { new_handle: new_handle }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Reload tenant_user association since handle is stored there
    tu = @tenant.tenant_users.find_by(user: @user)
    assert_equal new_handle, tu.handle, "User handle should have been updated"
  ensure
    TenantUser.unscoped.where(user: @user).update_all(handle: original_handle)
  end

  test "GET /u/:handle/settings/tokens/new returns 200 markdown with actions" do
    get "/u/#{@user.handle}/settings/tokens/new", headers: @headers
    assert_equal 200, response.status
    assert is_markdown?
    assert has_actions_section?, "New token page should have actions section"
    assert_match(/create_api_token/, response.body, "Should show create_api_token action")
  end

  test "POST create_api_token action creates token and returns 200 markdown" do
    initial_count = @user.api_tokens.count
    post "/u/#{@user.handle}/settings/tokens/new/actions/create_api_token",
      params: { name: "Test Token", read_write: "read" }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    @user.reload
    assert_equal initial_count + 1, @user.api_tokens.count, "New token should have been created"
    new_token = @user.api_tokens.last
    assert_equal "Test Token", new_token.name
  ensure
    @user.api_tokens.where(name: "Test Token").destroy_all
  end

  test "POST create_api_token action creates read_write token" do
    post "/u/#{@user.handle}/settings/tokens/new/actions/create_api_token",
      params: { name: "Write Token", read_write: "write" }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    new_token = ApiToken.find_by(name: "Write Token", user: @user)
    assert new_token, "Token should have been created"
    assert new_token.scopes.include?('create:all'), "Token should have write scopes (create:all), got: #{new_token.scopes}"
  ensure
    ApiToken.where(name: "Write Token", user: @user).destroy_all
  end

  test "GET token show page returns obfuscated token in markdown (security)" do
    # Create a token to view
    test_token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      name: "Security Test Token",
      scopes: ["read:all"]
    )
    plaintext = test_token.plaintext_token

    get "/u/#{@user.handle}/settings/tokens/#{test_token.id}", headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # The response should contain the obfuscated token, not the full token
    assert_includes response.body, test_token.obfuscated_token, "Response should include obfuscated token"
    refute_includes response.body, plaintext, "Response should NOT include full token (security risk)"
  ensure
    ApiToken.where(name: "Security Test Token", user: @user).destroy_all
  end

  test "GET /u/:handle/settings/subagents/new returns 200 markdown with actions" do
    get "/u/#{@user.handle}/settings/subagents/new", headers: @headers
    assert_equal 200, response.status
    assert is_markdown?
    assert has_actions_section?, "New subagent page should have actions section"
    assert_match(/create_subagent/, response.body, "Should show create_subagent action")
  end

  test "POST create_subagent action creates subagent and returns 200 markdown" do
    subagent_name = "Test Subagent #{SecureRandom.hex(4)}"
    initial_count = @user.subagents.count
    post "/u/#{@user.handle}/settings/subagents/new/actions/create_subagent",
      params: { name: subagent_name }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    @user.reload
    assert_equal initial_count + 1, @user.subagents.count, "New subagent should have been created"
    new_subagent = @user.subagents.find_by(name: subagent_name)
    assert new_subagent, "Subagent should exist"
    assert new_subagent.subagent?, "New user should be a subagent"
  ensure
    subagent = User.find_by(name: subagent_name)
    if subagent
      TenantUser.where(user: subagent).delete_all
      subagent.destroy
    end
  end

  test "POST create_subagent action with generate_token creates subagent with token" do
    subagent_name = "Subagent With Token #{SecureRandom.hex(4)}"
    post "/u/#{@user.handle}/settings/subagents/new/actions/create_subagent",
      params: { name: subagent_name, generate_token: true }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    new_subagent = User.find_by(name: subagent_name)
    assert new_subagent, "Subagent should exist"
    assert new_subagent.api_tokens.any?, "Subagent should have an API token"
  ensure
    subagent = User.find_by(name: subagent_name)
    if subagent
      subagent.api_tokens.delete_all
      TenantUser.where(user: subagent).delete_all
      subagent.destroy
    end
  end

  test "POST add_subagent_to_studio action adds subagent to studio" do
    # Create a subagent first
    subagent_name = "Studio Subagent #{SecureRandom.hex(4)}"
    subagent = User.create!(
      name: subagent_name,
      email: "#{SecureRandom.uuid}@not-real.com",
      user_type: "subagent",
      parent_id: @user.id,
    )
    @tenant.add_user!(subagent)

    # Create a second studio where user is admin
    second_superagent = Superagent.create!(
      tenant: @tenant,
      name: "Second Studio #{SecureRandom.hex(4)}",
      handle: "second-#{SecureRandom.hex(4)}",
      created_by: @user,
    )
    second_superagent.add_user!(@user, roles: ['admin'])
    second_superagent.enable_api!

    # Subagent should not be in the second studio initially
    refute subagent.superagents.include?(second_superagent), "Subagent should not be in studio initially"

    # Add subagent to studio via API
    post "/studios/#{second_superagent.handle}/settings/actions/add_subagent_to_studio",
      params: { subagent_id: subagent.id }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    subagent.reload
    assert subagent.superagents.include?(second_superagent), "Subagent should now be in the studio"
  ensure
    SuperagentMember.where(superagent: second_superagent).delete_all if second_superagent
    second_superagent&.destroy
    TenantUser.where(user: subagent).delete_all if subagent
    subagent&.destroy
  end

  test "POST remove_subagent_from_studio action removes subagent from studio" do
    # Create a subagent and add to studio
    subagent_name = "Remove Subagent #{SecureRandom.hex(4)}"
    subagent = User.create!(
      name: subagent_name,
      email: "#{SecureRandom.uuid}@not-real.com",
      user_type: "subagent",
      parent_id: @user.id,
    )
    @tenant.add_user!(subagent)

    # Create a second studio where user is admin
    second_superagent = Superagent.create!(
      tenant: @tenant,
      name: "Remove Studio #{SecureRandom.hex(4)}",
      handle: "remove-#{SecureRandom.hex(4)}",
      created_by: @user,
    )
    second_superagent.add_user!(@user, roles: ['admin'])
    second_superagent.add_user!(subagent)
    second_superagent.enable_api!

    # Subagent should be in the studio initially
    assert subagent.superagents.include?(second_superagent), "Subagent should be in studio initially"

    # Remove subagent from studio via API
    post "/studios/#{second_superagent.handle}/settings/actions/remove_subagent_from_studio",
      params: { subagent_id: subagent.id }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    subagent.reload
    # The superagent_member should be archived, not deleted
    superagent_member = SuperagentMember.unscoped.find_by(superagent: second_superagent, user: subagent)
    assert superagent_member.archived?, "Subagent's studio membership should be archived"
  ensure
    SuperagentMember.where(superagent: second_superagent).delete_all if second_superagent
    second_superagent&.destroy
    TenantUser.where(user: subagent).delete_all if subagent
    subagent&.destroy
  end

  test "Studio settings markdown shows add_subagent_to_studio action when subagents exist" do
    superagent_member = @user.superagent_members.find_by(superagent: @superagent)
    superagent_member.add_role!('admin')

    # Create a subagent that's not in this studio
    subagent = User.create!(
      name: "Available Subagent",
      email: "#{SecureRandom.uuid}@not-real.com",
      user_type: "subagent",
      parent_id: @user.id,
    )
    @tenant.add_user!(subagent)

    get "/studios/#{@superagent.handle}/settings", headers: @headers
    assert_equal 200, response.status
    assert is_markdown?
    assert_match(/add_subagent_to_studio/, response.body, "Should show add_subagent_to_studio action")
  ensure
    superagent_member&.remove_role!('admin')
    TenantUser.where(user: subagent).delete_all if subagent
    subagent&.destroy
  end

  # === Security Tests: Subagent Restrictions ===
  # These tests use API token authentication to simulate subagents acting on their own behalf

  test "Subagents cannot create subagents via API token - returns 403" do
    # Create a subagent with an API token
    subagent = User.create!(
      name: "Test Subagent",
      email: "#{SecureRandom.uuid}@not-real.com",
      user_type: "subagent",
      parent_id: @user.id,
    )
    tu = @tenant.add_user!(subagent)
    subagent.tenant_user = tu
    token = ApiToken.create!(
      user: subagent,
      tenant: @tenant,
      name: "Subagent Token",
      scopes: ApiToken.read_scopes + ApiToken.write_scopes,
      expires_at: 1.year.from_now,
    )

    # Use API token auth instead of session
    subagent_headers = {
      'Accept' => 'text/markdown',
      'Content-Type' => 'application/json',
      'Authorization' => "Bearer #{token.plaintext_token}",
    }

    # Try to create a subagent - should be blocked
    post "/u/#{subagent.handle}/settings/subagents/new/actions/create_subagent",
      params: { name: "Nested Subagent" }.to_json,
      headers: subagent_headers
    assert_equal 200, response.status  # render_action_error returns 200
    assert_match(/Only person accounts can create subagents/, response.body)
  ensure
    token&.destroy
    TenantUser.where(user: subagent).delete_all if subagent
    subagent&.destroy
  end

  test "Subagents cannot access create subagent page via API token - returns 403" do
    # Create a subagent with an API token
    subagent = User.create!(
      name: "Test Subagent",
      email: "#{SecureRandom.uuid}@not-real.com",
      user_type: "subagent",
      parent_id: @user.id,
    )
    tu = @tenant.add_user!(subagent)
    subagent.tenant_user = tu
    token = ApiToken.create!(
      user: subagent,
      tenant: @tenant,
      name: "Subagent Token",
      scopes: ApiToken.read_scopes + ApiToken.write_scopes,
      expires_at: 1.year.from_now,
    )

    subagent_headers = {
      'Accept' => 'text/markdown',
      'Authorization' => "Bearer #{token.plaintext_token}",
    }

    # Try to access create subagent page - should be blocked
    get "/u/#{subagent.handle}/settings/subagents/new", headers: subagent_headers
    assert_equal 403, response.status
    assert_match(/Only person accounts can create subagents/, response.body)
  ensure
    token&.destroy
    TenantUser.where(user: subagent).delete_all if subagent
    subagent&.destroy
  end

  test "Subagents cannot create their own API tokens via API token - returns 403" do
    # Create a subagent with an API token
    subagent = User.create!(
      name: "Test Subagent",
      email: "#{SecureRandom.uuid}@not-real.com",
      user_type: "subagent",
      parent_id: @user.id,
    )
    tu = @tenant.add_user!(subagent)
    subagent.tenant_user = tu
    token = ApiToken.create!(
      user: subagent,
      tenant: @tenant,
      name: "Subagent Token",
      scopes: ApiToken.read_scopes + ApiToken.write_scopes,
      expires_at: 1.year.from_now,
    )

    subagent_headers = {
      'Accept' => 'text/markdown',
      'Content-Type' => 'application/json',
      'Authorization' => "Bearer #{token.plaintext_token}",
    }

    # Try to create an API token for themselves - should be blocked
    post "/u/#{subagent.handle}/settings/tokens/new/actions/create_api_token",
      params: { name: "Self Token" }.to_json,
      headers: subagent_headers
    assert_equal 200, response.status  # render_action_error returns 200
    assert_match(/Only person accounts can create API tokens/, response.body)
  ensure
    token&.destroy
    TenantUser.where(user: subagent).delete_all if subagent
    subagent&.destroy
  end

  test "Subagents cannot access create API token page via API token - returns 403" do
    # Create a subagent with an API token
    subagent = User.create!(
      name: "Test Subagent",
      email: "#{SecureRandom.uuid}@not-real.com",
      user_type: "subagent",
      parent_id: @user.id,
    )
    tu = @tenant.add_user!(subagent)
    subagent.tenant_user = tu
    token = ApiToken.create!(
      user: subagent,
      tenant: @tenant,
      name: "Subagent Token",
      scopes: ApiToken.read_scopes + ApiToken.write_scopes,
      expires_at: 1.year.from_now,
    )

    subagent_headers = {
      'Accept' => 'text/markdown',
      'Authorization' => "Bearer #{token.plaintext_token}",
    }

    # Try to access create API token page - should be blocked
    get "/u/#{subagent.handle}/settings/tokens/new", headers: subagent_headers
    assert_equal 403, response.status
    assert_match(/Only person accounts can create API tokens/, response.body)
  ensure
    token&.destroy
    TenantUser.where(user: subagent).delete_all if subagent
    subagent&.destroy
  end

  test "Parents can still create API tokens for their subagents" do
    # Create a subagent
    subagent = User.create!(
      name: "Test Subagent",
      email: "#{SecureRandom.uuid}@not-real.com",
      user_type: "subagent",
      parent_id: @user.id,
    )
    tu = @tenant.add_user!(subagent)
    subagent.tenant_user = tu

    # Parent (person) creates token for subagent - should work
    post "/u/#{subagent.handle}/settings/tokens/new/actions/create_api_token",
      params: { name: "Parent Created Token" }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    token = ApiToken.find_by(name: "Parent Created Token", user: subagent)
    assert token, "Token should have been created for subagent"
  ensure
    ApiToken.where(user: subagent).delete_all if subagent
    TenantUser.where(user: subagent).delete_all if subagent
    subagent&.destroy
  end

  test "Subagents cannot execute add_subagent_to_studio via API token - returns 403" do
    # Create two subagents - one with API token, one to try to add
    acting_subagent = User.create!(
      name: "Acting Subagent",
      email: "#{SecureRandom.uuid}@not-real.com",
      user_type: "subagent",
      parent_id: @user.id,
    )
    other_subagent = User.create!(
      name: "Other Subagent",
      email: "#{SecureRandom.uuid}@not-real.com",
      user_type: "subagent",
      parent_id: @user.id,
    )
    @tenant.add_user!(acting_subagent)
    @tenant.add_user!(other_subagent)
    @superagent.add_user!(acting_subagent)
    token = ApiToken.create!(
      user: acting_subagent,
      tenant: @tenant,
      name: "Acting Subagent Token",
      scopes: ApiToken.read_scopes + ApiToken.write_scopes,
      expires_at: 1.year.from_now,
    )

    subagent_headers = {
      'Accept' => 'text/markdown',
      'Content-Type' => 'application/json',
      'Authorization' => "Bearer #{token.plaintext_token}",
    }

    # Try to add another subagent to studio - should be blocked
    post "/studios/#{@superagent.handle}/settings/actions/add_subagent_to_studio",
      params: { subagent_id: other_subagent.id }.to_json,
      headers: subagent_headers
    assert_equal 200, response.status
    assert_match(/Only person accounts can manage subagents/, response.body)
  ensure
    token&.destroy
    SuperagentMember.where(user: [acting_subagent, other_subagent]).delete_all
    TenantUser.where(user: [acting_subagent, other_subagent]).delete_all
    acting_subagent&.destroy
    other_subagent&.destroy
  end

  test "Subagents cannot execute remove_subagent_from_studio via API token - returns 403" do
    # Create two subagents - one with API token, one already in studio
    acting_subagent = User.create!(
      name: "Acting Subagent",
      email: "#{SecureRandom.uuid}@not-real.com",
      user_type: "subagent",
      parent_id: @user.id,
    )
    other_subagent = User.create!(
      name: "Other Subagent",
      email: "#{SecureRandom.uuid}@not-real.com",
      user_type: "subagent",
      parent_id: @user.id,
    )
    @tenant.add_user!(acting_subagent)
    @tenant.add_user!(other_subagent)
    @superagent.add_user!(acting_subagent)
    @superagent.add_user!(other_subagent)
    token = ApiToken.create!(
      user: acting_subagent,
      tenant: @tenant,
      name: "Acting Subagent Token",
      scopes: ApiToken.read_scopes + ApiToken.write_scopes,
      expires_at: 1.year.from_now,
    )

    subagent_headers = {
      'Accept' => 'text/markdown',
      'Content-Type' => 'application/json',
      'Authorization' => "Bearer #{token.plaintext_token}",
    }

    # Try to remove another subagent from studio - should be blocked
    post "/studios/#{@superagent.handle}/settings/actions/remove_subagent_from_studio",
      params: { subagent_id: other_subagent.id }.to_json,
      headers: subagent_headers
    assert_equal 200, response.status
    assert_match(/Only person accounts can manage subagents/, response.body)
  ensure
    token&.destroy
    SuperagentMember.where(user: [acting_subagent, other_subagent]).delete_all
    TenantUser.where(user: [acting_subagent, other_subagent]).delete_all
    acting_subagent&.destroy
    other_subagent&.destroy
  end

  # === Phase 3: Admin Panel Markdown API ===

  test "GET /admin redirects to appropriate admin section for admin user" do
    # Make user an admin
    tu = @tenant.tenant_users.find_by(user: @user)
    tu.add_role!('admin')

    get "/admin", headers: @headers
    # /admin is now a chooser that redirects based on user's admin roles
    assert_equal 302, response.status, "Admin chooser should redirect"
    assert_match(/tenant-admin|app-admin|system-admin|legacy-admin/, response.headers['Location'], "Should redirect to an admin section")
  ensure
    tu&.remove_role!('admin')
  end

  test "GET /admin returns 403 for non-admin user" do
    get "/admin", headers: @headers
    assert_equal 403, response.status
  end

  test "GET /tenant-admin/settings returns 200 markdown with actions for admin user" do
    tu = @tenant.tenant_users.find_by(user: @user)
    tu.add_role!('admin')

    get "/tenant-admin/settings", headers: @headers
    assert_equal 200, response.status
    assert is_markdown?
    assert_match(/Settings/, response.body, "Should show Settings heading")
    assert has_actions_section?, "Admin settings should have actions section"
    assert_match(/update_tenant_settings/, response.body, "Should show update_tenant_settings action")
  ensure
    tu&.remove_role!('admin')
  end

  test "POST update_tenant_settings action updates tenant and returns 200 markdown" do
    tu = @tenant.tenant_users.find_by(user: @user)
    tu.add_role!('admin')
    original_name = @tenant.name

    post "/tenant-admin/settings/actions/update_tenant_settings",
      params: { name: "Updated Tenant Name" }.to_json,
      headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    @tenant.reload
    assert_equal "Updated Tenant Name", @tenant.name, "Tenant name should have been updated"
  ensure
    tu&.remove_role!('admin')
    @tenant.update!(name: original_name)
  end

  # === Admin Panel Security: Subagent Access Requirements ===

  test "Subagent admin can access admin pages when both subagent AND parent are admins" do
    # Make parent user an admin
    parent_tu = @tenant.tenant_users.find_by(user: @user)
    parent_tu.add_role!('admin')

    # Create a subagent with admin role
    subagent = User.create!(
      name: "Admin Subagent",
      email: "#{SecureRandom.uuid}@not-real.com",
      user_type: "subagent",
      parent_id: @user.id,
    )
    subagent_tu = @tenant.add_user!(subagent)
    subagent_tu.add_role!('admin')
    token = ApiToken.create!(
      user: subagent,
      tenant: @tenant,
      name: "Admin Subagent Token",
      scopes: ApiToken.read_scopes + ApiToken.write_scopes,
      expires_at: 1.year.from_now,
    )

    subagent_headers = {
      'Accept' => 'text/markdown',
      'Authorization' => "Bearer #{token.plaintext_token}",
    }

    # Should be able to access admin page
    get "/tenant-admin", headers: subagent_headers
    assert_equal 200, response.status
    assert is_markdown?
  ensure
    parent_tu&.remove_role!('admin')
    token&.destroy
    TenantUser.where(user: subagent).delete_all if subagent
    subagent&.destroy
  end

  test "Subagent admin cannot access admin pages when parent is NOT admin" do
    # Parent is NOT an admin (no role added)

    # Create a subagent with admin role
    subagent = User.create!(
      name: "Admin Subagent",
      email: "#{SecureRandom.uuid}@not-real.com",
      user_type: "subagent",
      parent_id: @user.id,
    )
    subagent_tu = @tenant.add_user!(subagent)
    subagent_tu.add_role!('admin')
    token = ApiToken.create!(
      user: subagent,
      tenant: @tenant,
      name: "Admin Subagent Token",
      scopes: ApiToken.read_scopes + ApiToken.write_scopes,
      expires_at: 1.year.from_now,
    )

    subagent_headers = {
      'Accept' => 'text/markdown',
      'Authorization' => "Bearer #{token.plaintext_token}",
    }

    # Should NOT be able to access admin page because parent is not admin
    get "/tenant-admin", headers: subagent_headers
    assert_equal 403, response.status
    assert_match(/Subagent admin access requires both subagent and parent to be admins/, response.body)
  ensure
    token&.destroy
    TenantUser.where(user: subagent).delete_all if subagent
    subagent&.destroy
  end

  test "Subagent cannot access admin pages when subagent is NOT admin even if parent is" do
    # Make parent user an admin
    parent_tu = @tenant.tenant_users.find_by(user: @user)
    parent_tu.add_role!('admin')

    # Create a subagent WITHOUT admin role
    subagent = User.create!(
      name: "Non-Admin Subagent",
      email: "#{SecureRandom.uuid}@not-real.com",
      user_type: "subagent",
      parent_id: @user.id,
    )
    subagent_tu = @tenant.add_user!(subagent)
    # NOT adding admin role to subagent
    token = ApiToken.create!(
      user: subagent,
      tenant: @tenant,
      name: "Subagent Token",
      scopes: ApiToken.read_scopes + ApiToken.write_scopes,
      expires_at: 1.year.from_now,
    )

    subagent_headers = {
      'Accept' => 'text/markdown',
      'Authorization' => "Bearer #{token.plaintext_token}",
    }

    # Should NOT be able to access admin page because subagent is not admin
    get "/tenant-admin", headers: subagent_headers
    assert_equal 403, response.status
  ensure
    parent_tu&.remove_role!('admin')
    token&.destroy
    TenantUser.where(user: subagent).delete_all if subagent
    subagent&.destroy
  end

  # === Admin Panel Security: Subagent Production Write Restrictions ===

  test "Subagent admin can perform write operations in development/test environment" do
    # Make parent user an admin
    parent_tu = @tenant.tenant_users.find_by(user: @user)
    parent_tu.add_role!('admin')

    # Create a subagent with admin role
    subagent = User.create!(
      name: "Admin Subagent",
      email: "#{SecureRandom.uuid}@not-real.com",
      user_type: "subagent",
      parent_id: @user.id,
    )
    subagent_tu = @tenant.add_user!(subagent)
    subagent_tu.add_role!('admin')
    token = ApiToken.create!(
      user: subagent,
      tenant: @tenant,
      name: "Admin Subagent Token",
      scopes: ApiToken.read_scopes + ApiToken.write_scopes,
      expires_at: 1.year.from_now,
    )

    subagent_headers = {
      'Accept' => 'text/markdown',
      'Content-Type' => 'application/json',
      'Authorization' => "Bearer #{token.plaintext_token}",
    }

    original_name = @tenant.name

    # In test environment, should be able to perform write operations
    post "/tenant-admin/settings/actions/update_tenant_settings",
      params: { name: "Subagent Updated Name" }.to_json,
      headers: subagent_headers
    assert_equal 200, response.status
    assert is_markdown?

    @tenant.reload
    assert_equal "Subagent Updated Name", @tenant.name, "Subagent should be able to update in test env"
  ensure
    parent_tu&.remove_role!('admin')
    token&.destroy
    TenantUser.where(user: subagent).delete_all if subagent
    subagent&.destroy
    @tenant.update!(name: original_name) if @tenant
  end

  test "Subagent admin cannot perform write operations in production environment" do
    # Make parent user an admin
    parent_tu = @tenant.tenant_users.find_by(user: @user)
    parent_tu.add_role!('admin')

    # Create a subagent with admin role
    subagent = User.create!(
      name: "Admin Subagent",
      email: "#{SecureRandom.uuid}@not-real.com",
      user_type: "subagent",
      parent_id: @user.id,
    )
    subagent_tu = @tenant.add_user!(subagent)
    subagent_tu.add_role!('admin')
    token = ApiToken.create!(
      user: subagent,
      tenant: @tenant,
      name: "Admin Subagent Token",
      scopes: ApiToken.read_scopes + ApiToken.write_scopes,
      expires_at: 1.year.from_now,
    )

    subagent_headers = {
      'Accept' => 'text/markdown',
      'Content-Type' => 'application/json',
      'Authorization' => "Bearer #{token.plaintext_token}",
    }

    # Simulate production environment
    Thread.current[:simulate_production] = true
    begin
      # Should NOT be able to perform write operations in production
      post "/tenant-admin/settings/actions/update_tenant_settings",
        params: { name: "Should Not Update" }.to_json,
        headers: subagent_headers
      assert_equal 403, response.status
      assert_match(/Subagents cannot perform admin write operations in production/, response.body)
    ensure
      Thread.current[:simulate_production] = nil
    end
  ensure
    parent_tu&.remove_role!('admin')
    token&.destroy
    TenantUser.where(user: subagent).delete_all if subagent
    subagent&.destroy
  end

  test "Subagent admin can still read admin pages in production environment" do
    # Make parent user an admin
    parent_tu = @tenant.tenant_users.find_by(user: @user)
    parent_tu.add_role!('admin')

    # Create a subagent with admin role
    subagent = User.create!(
      name: "Admin Subagent",
      email: "#{SecureRandom.uuid}@not-real.com",
      user_type: "subagent",
      parent_id: @user.id,
    )
    subagent_tu = @tenant.add_user!(subagent)
    subagent_tu.add_role!('admin')
    token = ApiToken.create!(
      user: subagent,
      tenant: @tenant,
      name: "Admin Subagent Token",
      scopes: ApiToken.read_scopes + ApiToken.write_scopes,
      expires_at: 1.year.from_now,
    )

    subagent_headers = {
      'Accept' => 'text/markdown',
      'Authorization' => "Bearer #{token.plaintext_token}",
    }

    # Simulate production environment
    Thread.current[:simulate_production] = true
    begin
      # Should be able to READ admin pages in production
      get "/tenant-admin", headers: subagent_headers
      assert_equal 200, response.status
      assert is_markdown?
    ensure
      Thread.current[:simulate_production] = nil
    end
  ensure
    parent_tu&.remove_role!('admin')
    token&.destroy
    TenantUser.where(user: subagent).delete_all if subagent
    subagent&.destroy
  end

  test "Person admin can still perform write operations in production environment" do
    # Make user an admin
    tu = @tenant.tenant_users.find_by(user: @user)
    tu.add_role!('admin')
    original_name = @tenant.name

    # Simulate production environment
    Thread.current[:simulate_production] = true
    begin
      # Person admin should still be able to write in production
      post "/tenant-admin/settings/actions/update_tenant_settings",
        params: { name: "Person Updated Name" }.to_json,
        headers: @headers
      assert_equal 200, response.status
      assert is_markdown?

      @tenant.reload
      assert_equal "Person Updated Name", @tenant.name, "Person admin should be able to update in production"
    ensure
      Thread.current[:simulate_production] = nil
    end
  ensure
    tu&.remove_role!('admin')
    @tenant.update!(name: original_name)
  end

  test "Admin settings page hides actions for subagents in production" do
    # Make parent user an admin
    parent_tu = @tenant.tenant_users.find_by(user: @user)
    parent_tu.add_role!('admin')

    # Create a subagent with admin role
    subagent = User.create!(
      name: "Admin Subagent",
      email: "#{SecureRandom.uuid}@not-real.com",
      user_type: "subagent",
      parent_id: @user.id,
    )
    subagent_tu = @tenant.add_user!(subagent)
    subagent_tu.add_role!('admin')
    token = ApiToken.create!(
      user: subagent,
      tenant: @tenant,
      name: "Admin Subagent Token",
      scopes: ApiToken.read_scopes,
      expires_at: 1.year.from_now,
    )

    subagent_headers = {
      'Accept' => 'text/markdown',
      'Authorization' => "Bearer #{token.plaintext_token}",
    }

    # Simulate production environment
    Thread.current[:simulate_production] = true
    begin
      get "/tenant-admin/settings", headers: subagent_headers
      assert_equal 200, response.status
      assert is_markdown?
      # Should show read-only message instead of actions
      assert_match(/read-only access/, response.body, "Should show read-only message for subagent in production")
    ensure
      Thread.current[:simulate_production] = nil
    end
  ensure
    parent_tu&.remove_role!('admin')
    token&.destroy
    TenantUser.where(user: subagent).delete_all if subagent
    subagent&.destroy
  end

  # === Phase 4: File Attachments Markdown API ===

  test "Note show page displays attachments section when attachments exist" do
    note = create_note(text: "Note with attachment")
    # Create an attachment
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("test file content"),
      filename: "test.txt",
      content_type: "text/plain"
    )
    attachment = Attachment.create!(
      tenant_id: @tenant.id,
      superagent_id: @superagent.id,
      attachable: note,
      file: blob,
      created_by: @user,
      updated_by: @user
    )

    get note.path, headers: @headers
    assert_equal 200, response.status
    assert is_markdown?
    assert_match(/Attachments \(1\)/, response.body, "Should show Attachments section with count")
    assert_match(/test\.txt/, response.body, "Should show filename")
  ensure
    attachment&.destroy
    note&.destroy
  end

  test "Note show page does not display attachments section when no attachments" do
    note = create_note(text: "Note without attachment")

    get note.path, headers: @headers
    assert_equal 200, response.status
    assert is_markdown?
    refute_match(/## Attachments/, response.body, "Should not show Attachments section")
  ensure
    note&.destroy
  end

  test "GET /n/:id/edit/actions/add_attachment describes add_attachment action" do
    @tenant.settings["allow_file_uploads"] = "true"
    @tenant.save!
    @superagent.settings["allow_file_uploads"] = "true"
    @superagent.save!
    note = create_note(text: "Test note")

    get "#{note.path}/edit/actions/add_attachment", headers: @headers
    assert_equal 200, response.status
    assert is_markdown?
    assert_match(/add_attachment/, response.body)
    assert_match(/file/, response.body, "Should describe file parameter")
  ensure
    note&.destroy
  end

  test "POST /n/:id/edit/actions/add_attachment adds attachment via base64" do
    @tenant.settings["allow_file_uploads"] = "true"
    @tenant.save!
    @superagent.settings["allow_file_uploads"] = "true"
    @superagent.save!
    note = create_note(text: "Test note for attachment")
    file_content = "Hello, this is test file content"
    encoded_content = Base64.encode64(file_content)

    post "#{note.path}/edit/actions/add_attachment",
      params: {
        file: {
          data: encoded_content,
          content_type: "text/plain",
          filename: "test_upload.txt"
        }
      }.to_json,
      headers: @headers

    assert_equal 200, response.status
    assert is_markdown?
    assert_match(/added successfully/, response.body)

    note.reload
    assert_equal 1, note.attachments.count, "Note should have one attachment"
    assert_equal "test_upload.txt", note.attachments.first.filename
  ensure
    note&.attachments&.destroy_all
    note&.destroy
  end

  test "GET /n/:id/attachments/:attachment_id/actions describes remove_attachment action" do
    note = create_note(text: "Note with attachment")
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("test content"),
      filename: "remove_me.txt",
      content_type: "text/plain"
    )
    attachment = Attachment.create!(
      tenant_id: @tenant.id,
      superagent_id: @superagent.id,
      attachable: note,
      file: blob,
      created_by: @user,
      updated_by: @user
    )

    get "#{note.path}/attachments/#{attachment.id}/actions", headers: @headers
    assert_equal 200, response.status
    assert is_markdown?
    assert_match(/remove_attachment/, response.body)
  ensure
    attachment&.destroy
    note&.destroy
  end

  test "POST /n/:id/attachments/:attachment_id/actions/remove_attachment removes attachment" do
    note = create_note(text: "Note with attachment to remove")
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("test content"),
      filename: "to_remove.txt",
      content_type: "text/plain"
    )
    attachment = Attachment.create!(
      tenant_id: @tenant.id,
      superagent_id: @superagent.id,
      attachable: note,
      file: blob,
      created_by: @user,
      updated_by: @user
    )
    attachment_id = attachment.id

    post "#{note.path}/attachments/#{attachment_id}/actions/remove_attachment",
      headers: @headers

    assert_equal 200, response.status
    assert is_markdown?
    assert_match(/removed successfully/, response.body)

    note.reload
    assert_equal 0, note.attachments.count, "Note should have no attachments"
  ensure
    note&.destroy
  end

  test "Decision show page displays attachments section" do
    decision = create_decision(question: "Decision with attachment?")
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("decision attachment"),
      filename: "decision.txt",
      content_type: "text/plain"
    )
    attachment = Attachment.create!(
      tenant_id: @tenant.id,
      superagent_id: @superagent.id,
      attachable: decision,
      file: blob,
      created_by: @user,
      updated_by: @user
    )

    get decision.path, headers: @headers
    assert_equal 200, response.status
    assert is_markdown?
    assert_match(/Attachments \(1\)/, response.body)
    assert_match(/decision\.txt/, response.body)
  ensure
    attachment&.destroy
    decision&.destroy
  end

  test "Commitment show page displays attachments section" do
    commitment = create_commitment(title: "Commitment with attachment")
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("commitment attachment"),
      filename: "commitment.txt",
      content_type: "text/plain"
    )
    attachment = Attachment.create!(
      tenant_id: @tenant.id,
      superagent_id: @superagent.id,
      attachable: commitment,
      file: blob,
      created_by: @user,
      updated_by: @user
    )

    get commitment.path, headers: @headers
    assert_equal 200, response.status
    assert is_markdown?
    assert_match(/Attachments \(1\)/, response.body)
    assert_match(/commitment\.txt/, response.body)
  ensure
    attachment&.destroy
    commitment&.destroy
  end

  # === Notification Count in Markdown UI ===

  test "markdown UI displays unread notification count in nav bar" do
    # Create another user to trigger a notification
    other_user = User.create!(
      name: "Other User",
      email: "other-notif-#{SecureRandom.hex(4)}@test.com",
    )
    @tenant.add_user!(other_user)
    @superagent.add_user!(other_user)

    # Create a notification for @user
    event = Event.create!(
      tenant: @tenant,
      superagent: @superagent,
      event_type: "note.created",
      actor: other_user,
    )
    notification = Notification.create!(
      tenant: @tenant,
      event: event,
      notification_type: "mention",
      title: "Test notification",
    )
    NotificationRecipient.create!(
      tenant: @tenant,
      notification: notification,
      user: @user,
      channel: "in_app",
      status: "delivered",
    )

    # Request a markdown page
    get "/", headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Check that the nav bar includes the notification count
    # The format is: | [<%= @unread_notification_count %>](/notifications) |
    assert_match(/\| \[1\]\(\/notifications\) \|/, response.body,
      "Nav bar should display unread notification count of 1")
  ensure
    NotificationRecipient.where(notification: notification).delete_all if notification
    notification&.destroy
    event&.destroy
    SuperagentMember.where(user: other_user).delete_all if other_user
    TenantUser.where(user: other_user).delete_all if other_user
    other_user&.destroy
  end

  test "markdown UI displays zero notification count when no unread notifications" do
    # Ensure no notifications exist for this user
    NotificationRecipient.where(user: @user).delete_all

    # Request a markdown page
    get "/", headers: @headers
    assert_equal 200, response.status
    assert is_markdown?

    # Check that the nav bar shows 0
    assert_match(/\| \[0\]\(\/notifications\) \|/, response.body,
      "Nav bar should display notification count of 0 when no unread notifications")
  end

  test "markdown UI notification count updates after marking notification as read" do
    # Create another user to trigger a notification
    other_user = User.create!(
      name: "Other User",
      email: "other-notif2-#{SecureRandom.hex(4)}@test.com",
    )
    @tenant.add_user!(other_user)
    @superagent.add_user!(other_user)

    # Create a notification for @user
    event = Event.create!(
      tenant: @tenant,
      superagent: @superagent,
      event_type: "note.created",
      actor: other_user,
    )
    notification = Notification.create!(
      tenant: @tenant,
      event: event,
      notification_type: "mention",
      title: "Test notification",
    )
    recipient = NotificationRecipient.create!(
      tenant: @tenant,
      notification: notification,
      user: @user,
      channel: "in_app",
      status: "delivered",
    )

    # Verify count is 1 initially
    get "/", headers: @headers
    assert_match(/\| \[1\]\(\/notifications\) \|/, response.body,
      "Nav bar should display unread notification count of 1")

    # Mark the notification as read (unread scope checks read_at: nil)
    recipient.update!(status: "read", read_at: Time.current)

    # Check that count is now 0
    get "/", headers: @headers
    assert_match(/\| \[0\]\(\/notifications\) \|/, response.body,
      "Nav bar should display notification count of 0 after marking as read")
  ensure
    NotificationRecipient.where(notification: notification).delete_all if notification
    notification&.destroy
    event&.destroy
    SuperagentMember.where(user: other_user).delete_all if other_user
    TenantUser.where(user: other_user).delete_all if other_user
    other_user&.destroy
  end

  # === Threaded Comments in Markdown UI ===

  test "note with no comments shows 'No comments yet' in markdown" do
    note = create_note(superagent: @superagent, created_by: @user, title: "Note without comments")

    get note.path, headers: @headers
    assert_equal 200, response.status
    assert is_markdown?
    assert_match(/## Comments \(0\)/, response.body, "Should show Comments section with count 0")
    assert_match(/No comments yet\./, response.body, "Should show 'No comments yet' message")
  ensure
    note&.destroy
  end

  test "note with single comment shows comment in markdown" do
    note = create_note(superagent: @superagent, created_by: @user, title: "Note with comment")
    comment = note.add_comment(text: "This is a test comment", created_by: @user)

    get note.path, headers: @headers
    assert_equal 200, response.status
    assert is_markdown?
    assert_match(/## Comments \(1\)/, response.body, "Should show Comments section with count 1")
    assert_match(/This is a test comment/, response.body, "Should show comment text")
    assert_match(/\[This is a test comment\]\(#{comment.path}\)/, response.body, "Should link to comment")
  ensure
    comment&.destroy
    note&.destroy
  end

  test "note with threaded comments shows replies indented in markdown" do
    note = create_note(superagent: @superagent, created_by: @user, title: "Note with threaded comments")
    top_level_comment = note.add_comment(text: "Top level comment", created_by: @user)
    reply = top_level_comment.add_comment(text: "Reply to top level", created_by: @user)

    get note.path, headers: @headers
    assert_equal 200, response.status
    assert is_markdown?
    assert_match(/## Comments \(1\)/, response.body, "Should show Comments section with top-level count")
    assert_match(/\* .+Top level comment/, response.body, "Should show top-level comment as main bullet")
    assert_match(/  \* .+Reply to top level/, response.body, "Should show reply indented with two spaces")
  ensure
    reply&.destroy
    top_level_comment&.destroy
    note&.destroy
  end

  test "nested reply shows 'Replying to @handle' context in markdown" do
    note = create_note(superagent: @superagent, created_by: @user, title: "Note with nested replies")
    top_level_comment = note.add_comment(text: "Top level comment", created_by: @user)
    first_reply = top_level_comment.add_comment(text: "First reply", created_by: @user)
    # This is a reply to first_reply, not to top_level_comment, so it should show context
    nested_reply = first_reply.add_comment(text: "Nested reply to first reply", created_by: @user)

    get note.path, headers: @headers
    assert_equal 200, response.status
    assert is_markdown?
    # The nested reply should show "↳ Replying to @handle:" because it's a reply to first_reply, not top_level_comment
    assert_match(/↳ Replying to @#{@user.handle}:/, response.body, "Should show 'Replying to @handle' for nested reply")
    assert_match(/Nested reply to first reply/, response.body, "Should show nested reply text")
  ensure
    nested_reply&.destroy
    first_reply&.destroy
    top_level_comment&.destroy
    note&.destroy
  end

  test "decision with threaded comments shows them in markdown" do
    decision = create_decision(superagent: @superagent, created_by: @user, question: "Decision with comments?")
    comment = decision.add_comment(text: "Comment on decision", created_by: @user)

    get decision.path, headers: @headers
    assert_equal 200, response.status
    assert is_markdown?
    assert_match(/## Comments \(1\)/, response.body, "Should show Comments section")
    assert_match(/Comment on decision/, response.body, "Should show comment text")
  ensure
    comment&.destroy
    decision&.destroy
  end

  test "commitment with threaded comments shows them in markdown" do
    commitment = create_commitment(superagent: @superagent, created_by: @user, title: "Commitment with comments")
    comment = commitment.add_comment(text: "Comment on commitment", created_by: @user)

    get commitment.path, headers: @headers
    assert_equal 200, response.status
    assert is_markdown?
    assert_match(/## Comments \(1\)/, response.body, "Should show Comments section")
    assert_match(/Comment on commitment/, response.body, "Should show comment text")
  ensure
    comment&.destroy
    commitment&.destroy
  end

  test "representation session with comments shows them in markdown" do
    # Create a representation session
    session = RepresentationSession.create!(
      tenant: @tenant,
      superagent: @superagent,
      representative_user: @user,
      trustee_user: @user,
      confirmed_understanding: true,
      began_at: 1.hour.ago,
      ended_at: 30.minutes.ago,
    )
    comment = session.add_comment(text: "Comment on representation session", created_by: @user)

    get session.path, headers: @headers
    assert_equal 200, response.status
    assert is_markdown?
    assert_match(/## Comments \(1\)/, response.body, "Should show Comments section")
    assert_match(/Comment on representation session/, response.body, "Should show comment text")
    assert_match(/add_comment/, response.body, "Should show add_comment action")
  ensure
    comment&.destroy
    session&.destroy
  end

  # Subagent task run markdown tests
  test "GET subagent task run returns markdown and strips JSON from think steps" do
    # Enable subagents feature for this tenant
    @tenant.enable_feature_flag!("subagents")

    # Create a subagent
    subagent = User.create!(
      name: "Task Run Test Agent",
      email: "task-run-test-#{SecureRandom.hex(4)}@not-real.com",
      user_type: "subagent",
      parent_id: @user.id,
    )
    tu = @tenant.add_user!(subagent)
    subagent.tenant_user = tu

    # Create a task run with a think step containing JSON
    think_response_with_json = <<~RESPONSE
      I will navigate to the studio to create a note.

      Let me check the available actions first.

      ```json
      {"type": "navigate", "path": "/studios/test"}
      ```
    RESPONSE

    task_run = SubagentTaskRun.create!(
      tenant: @tenant,
      subagent: subagent,
      initiated_by: @user,
      task: "Create a test note",
      max_steps: 15,
      status: "completed",
      success: true,
      final_message: "Task completed successfully",
      steps_count: 2,
      steps_data: [
        {
          type: "think",
          timestamp: Time.current.iso8601,
          detail: {
            step_number: 0,
            response_preview: think_response_with_json,
          },
        },
        {
          type: "done",
          timestamp: Time.current.iso8601,
          detail: {
            message: "Task completed successfully",
          },
        },
      ],
      started_at: 1.minute.ago,
      completed_at: Time.current,
    )

    get "/subagents/#{subagent.handle}/runs/#{task_run.id}", headers: @headers
    assert_equal 200, response.status
    assert response.content_type.starts_with?("text/markdown"), "Response should be markdown"

    # Should include the reasoning text
    assert_match(/I will navigate to the studio/, response.body, "Should include reasoning text")
    assert_match(/Let me check the available actions/, response.body, "Should include reasoning text")

    # Should NOT include the JSON block (it's stripped for display)
    assert_no_match(/```json/, response.body, "Should not include fenced JSON block")
    assert_no_match(/"type":\s*"navigate"/, response.body, "Should not include JSON action")
  ensure
    task_run&.destroy
    TenantUser.where(user: subagent).delete_all if subagent
    subagent&.destroy
  end
end