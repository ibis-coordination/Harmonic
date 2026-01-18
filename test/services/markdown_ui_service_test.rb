require "test_helper"

class MarkdownUiServiceTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @superagent = @global_superagent
    @user = @global_user
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

  test "navigate without layout excludes YAML front matter" do
    result = @service.navigate("/", include_layout: false)
    assert_nil result[:error]
    refute_includes result[:content], "---\napp: Harmonic"
  end

  test "navigate with layout includes YAML front matter" do
    result = @service.navigate("/", include_layout: true)
    assert_nil result[:error]
    assert_includes result[:content], "app: Harmonic"
  end

  test "navigate returns available actions" do
    result = @service.navigate("/studios/#{@superagent.handle}/note")
    assert_nil result[:error]
    assert result[:actions].is_a?(Array)
    action_names = result[:actions].map { |a| a[:name] }
    assert_includes action_names, "create_note"
  end

  test "navigate to invalid path returns error" do
    result = @service.navigate("/this/path/does/not/exist")
    assert result[:error].present?
    assert_includes result[:error], "Route not found"
  end

  # set_path tests

  test "set_path returns true for valid path" do
    result = @service.set_path("/studios/#{@superagent.handle}")
    assert result
  end

  test "set_path returns false for invalid path" do
    result = @service.set_path("/this/path/does/not/exist")
    assert_not result
  end

  test "set_path allows execute_action without navigate" do
    @service.set_path("/studios/#{@superagent.handle}/note")
    result = @service.execute_action("create_note", { text: "Test note via set_path" })
    assert result[:success], "Expected success, got error: #{result[:error]}"
    assert_includes result[:content], "Note created"
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
    result = service.execute_action("create_note", { text: "Test" })
    assert_not result[:success]
    assert_includes result[:error], "No current path"
  end

  test "execute_action create_note creates a note" do
    @service.navigate("/studios/#{@superagent.handle}/note")
    result = @service.execute_action("create_note", { text: "Test note content" })
    assert result[:success], "Expected success, got error: #{result[:error]}"
    assert_includes result[:content], "Note created"
  end

  test "execute_action confirm_read confirms read on note" do
    note = Note.create!(
      title: "Test Note for Read",
      text: "Content",
      created_by: @user,
      deadline: Time.current + 1.week
    )
    @service.navigate(note.path)
    result = @service.execute_action("confirm_read", {})
    assert result[:success], "Expected success, got error: #{result[:error]}"
    assert_includes result[:content], "Read confirmed"
  end

  test "execute_action with unknown action returns error" do
    @service.navigate("/")
    result = @service.execute_action("nonexistent_action", {})
    assert_not result[:success]
    assert_includes result[:error], "Unknown action"
  end

  # ViewContext tests

  test "view context provides correct instance variables" do
    result = @service.navigate("/studios/#{@superagent.handle}")
    assert_nil result[:error]
    # The content should use instance variables correctly
    assert_includes result[:content], @superagent.name
  end

  test "view context loads notification count for logged in user" do
    context = MarkdownUiService::ViewContext.new(
      tenant: @tenant,
      superagent: @superagent,
      user: @user,
      current_path: "/"
    )
    assert context.unread_notification_count >= 0
  end

  # ResourceLoader tests

  test "resource loader populates note for note show page" do
    note = Note.create!(
      title: "Resource Loader Test",
      text: "Testing resource loading",
      created_by: @user,
      deadline: Time.current + 1.week
    )
    route_info = {
      controller: "notes",
      action: "show",
      params: { id: note.truncated_id },
    }
    context = MarkdownUiService::ViewContext.new(
      tenant: @tenant,
      superagent: @superagent,
      user: @user,
      current_path: note.path
    )
    loader = MarkdownUiService::ResourceLoader.new(
      context: context,
      route_info: route_info
    )
    loader.load_resources

    assert_equal note, context.note
    assert_equal note.title, context.page_title
    assert context.note_reader.present?
  end

  test "resource loader populates pinned items for studio show" do
    route_info = {
      controller: "studios",
      action: "show",
      params: { superagent_handle: @superagent.handle },
    }
    context = MarkdownUiService::ViewContext.new(
      tenant: @tenant,
      superagent: @superagent,
      user: @user,
      current_path: "/studios/#{@superagent.handle}"
    )
    loader = MarkdownUiService::ResourceLoader.new(
      context: context,
      route_info: route_info
    )
    loader.load_resources

    assert context.pinned_items.is_a?(Array)
    assert_equal @superagent.name, context.page_title
  end

  # Thread-local context tests

  test "service properly sets and clears thread-local context" do
    # Clear any existing context
    Tenant.clear_thread_scope
    Superagent.clear_thread_scope

    service = MarkdownUiService.new(
      tenant: @tenant,
      superagent: @superagent,
      user: @user
    )

    # Before navigate, context should be cleared
    assert_nil Tenant.current_id

    # After navigate completes, context should be cleared again
    service.navigate("/")
    assert_nil Tenant.current_id
  end

  # Decision tests

  test "navigate to decision page shows decision content" do
    decision = Decision.create!(
      question: "What should we do?",
      description: "A test decision",
      created_by: @user,
      deadline: Time.current + 1.week
    )
    result = @service.navigate(decision.path)
    assert_nil result[:error], "Expected no error, got: #{result[:error]}"
    assert_includes result[:content], decision.question
  end

  # Authorization tests

  test "navigate without user returns error when tenant requires login" do
    service = MarkdownUiService.new(
      tenant: @tenant,
      superagent: @superagent,
      user: nil
    )
    result = service.navigate("/")
    assert result[:error].present?
    assert_includes result[:error], "Authentication required"
  end

  test "navigate with non-member user returns tenant error" do
    # Create a user who is not a member of the tenant
    other_user = User.create!(
      name: "Outsider",
      email: "outsider@example.com",
      user_type: "person"
    )
    service = MarkdownUiService.new(
      tenant: @tenant,
      superagent: @superagent,
      user: other_user
    )
    result = service.navigate("/")
    assert result[:error].present?
    assert_includes result[:error], "not a member of this tenant"
  end

  test "navigate with tenant member but non-studio member returns studio error" do
    # Create a user who is a tenant member but not a studio member
    other_user = User.create!(
      name: "Tenant Member",
      email: "tenant-member@example.com",
      user_type: "person"
    )
    @tenant.add_user!(other_user)

    # Use a non-main superagent (the global one should not be main)
    service = MarkdownUiService.new(
      tenant: @tenant,
      superagent: @superagent,
      user: other_user
    )
    result = service.navigate("/")

    # If superagent is main, access should be allowed; otherwise blocked
    if @superagent.is_main_superagent?
      assert_nil result[:error]
    else
      assert result[:error].present?
      assert_includes result[:error], "not a member of this studio"
    end
  end

  test "set_path returns false for unauthorized user" do
    other_user = User.create!(
      name: "Outsider",
      email: "outsider2@example.com",
      user_type: "person"
    )
    service = MarkdownUiService.new(
      tenant: @tenant,
      superagent: @superagent,
      user: other_user
    )
    result = service.set_path("/studios/#{@superagent.handle}")
    assert_not result
  end
end
