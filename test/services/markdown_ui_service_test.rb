require "test_helper"

class MarkdownUiServiceTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @superagent = @global_superagent
    @user = @global_user

    # Enable API for internal requests to work
    @tenant.enable_feature_flag!("api")
    @superagent.enable_feature_flag!("api")

    # Set thread-local context for tests
    Superagent.scope_thread_to_superagent(
      subdomain: @tenant.subdomain,
      handle: @superagent.handle
    )
    @service = MarkdownUiService.new(
      tenant: @tenant,
      superagent: @superagent,
      user: @user
    )
  end

  # Navigation tests

  test "navigate to home page returns content" do
    result = @service.navigate("/")
    assert_nil result[:error], "Expected no error, got: #{result[:error]}"
    assert_equal "/", result[:path]
    assert result[:content].present?, "Expected content to be present"
  end

  test "navigate to studio show page returns content with studio name" do
    result = @service.navigate("/studios/#{@superagent.handle}")
    assert_nil result[:error], "Expected no error, got: #{result[:error]}"
    assert_includes result[:content], @superagent.name
  end

  test "navigate to note page returns note content" do
    note = Note.create!(
      title: "Test Note",
      text: "This is a test note.",
      created_by: @user,
      deadline: Time.current + 1.week
    )
    result = @service.navigate(note.path)
    assert_nil result[:error], "Expected no error, got: #{result[:error]}"
    assert_includes result[:content], note.title
    assert_includes result[:content], note.text
  end

  test "navigate with layout includes YAML front matter" do
    result = @service.navigate("/", include_layout: true)
    assert_nil result[:error]
    assert_includes result[:content], "app: Harmonic"
  end

  test "navigate returns available actions from YAML frontmatter" do
    result = @service.navigate("/studios/#{@superagent.handle}/note")
    assert_nil result[:error], "Expected no error, got: #{result[:error]}"
    assert result[:actions].is_a?(Array), "Expected actions to be an array, got: #{result[:actions].class}"
    action_names = result[:actions].map { |a| a["name"] }
    assert_includes action_names, "create_note"
  end

  test "navigate to invalid path returns error" do
    result = @service.navigate("/this/path/does/not/exist")
    assert result[:error].present?
    assert_includes result[:error], "No route matches"
  end

  # set_path tests

  test "set_path returns true" do
    result = @service.set_path("/studios/#{@superagent.handle}")
    assert result
  end

  test "set_path sets current_path" do
    @service.set_path("/studios/#{@superagent.handle}")
    assert_equal "/studios/#{@superagent.handle}", @service.current_path
  end

  # Action execution tests

  test "execute_action without navigating first returns error" do
    service = MarkdownUiService.new(
      tenant: @tenant,
      superagent: @superagent,
      user: @user
    )
    result = service.execute_action("create_note", { text: "test" })
    assert_not result[:success]
    assert_includes result[:error], "No current path"
  end

  test "execute_action create_note creates note and returns success" do
    @service.navigate("/studios/#{@superagent.handle}/note")
    text = "Test note created via V2 service - #{SecureRandom.hex(4)}"
    result = @service.execute_action("create_note", { text: text })
    assert result[:success], "Expected success, got error: #{result[:error]}"

    # Verify note was created
    note = Note.find_by(text: text)
    assert_not_nil note, "Note should have been created"
    assert_equal @user, note.created_by
  end

  test "execute_action with set_path creates note" do
    @service.set_path("/studios/#{@superagent.handle}/note")
    text = "Test note via set_path - #{SecureRandom.hex(4)}"
    result = @service.execute_action("create_note", { text: text })
    assert result[:success], "Expected success, got error: #{result[:error]}"

    # Verify note was created
    note = Note.find_by(text: text)
    assert_not_nil note
  end

  test "execute_action works when already on action description page" do
    # Navigate to the action description page (like an agent exploring the action)
    @service.navigate("/studios/#{@superagent.handle}/note/actions/create_note")

    # Now execute the action - it should work without double-appending /actions/create_note
    text = "Test note from action page - #{SecureRandom.hex(4)}"
    result = @service.execute_action("create_note", { text: text })
    assert result[:success], "Expected success when executing from action description page, got error: #{result[:error]}"

    # Verify note was created
    note = Note.find_by(text: text)
    assert_not_nil note, "Note should have been created"
  end

  test "execute_action confirm_read confirms note read" do
    note = Note.create!(
      title: "Test Note for Confirm",
      text: "This is a test note to confirm.",
      created_by: @user,
      deadline: Time.current + 1.week
    )

    @service.navigate(note.path)
    result = @service.execute_action("confirm_read", {})
    assert result[:success], "Expected success, got error: #{result[:error]}"

    # Verify confirmation was recorded
    note.reload
    assert note.user_has_read?(@user)
  end

  # Internal token tests

  test "internal token is created for user" do
    @service.navigate("/studios/#{@superagent.handle}")

    # Check that an internal token was created
    token = ApiToken.internal.find_by(user: @user, tenant: @tenant)
    assert_not_nil token, "Internal token should have been created"
    assert token.internal?
    assert token.decrypted_token.present?
  end

  test "internal token is reused on subsequent requests" do
    @service.navigate("/studios/#{@superagent.handle}")
    token1 = ApiToken.internal.find_by(user: @user, tenant: @tenant)

    @service.navigate("/studios/#{@superagent.handle}/note")
    token2 = ApiToken.internal.find_by(user: @user, tenant: @tenant)

    assert_equal token1.id, token2.id, "Same token should be reused"
  end

  # Dynamic superagent switching tests

  test "navigate to different studio switches context" do
    # Create a second studio with API enabled
    other_studio = Superagent.create!(
      tenant: @tenant,
      handle: "other-studio-#{SecureRandom.hex(4)}",
      name: "Other Studio",
      superagent_type: "studio",
      created_by: @user,
      updated_by: @user
    )
    other_studio.enable_feature_flag!("api")
    other_studio.add_user!(@user)

    result = @service.navigate("/studios/#{other_studio.handle}")
    assert_nil result[:error]
    assert_includes result[:content], other_studio.name
  end

end
