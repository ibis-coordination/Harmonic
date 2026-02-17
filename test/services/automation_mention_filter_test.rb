# typed: false

require "test_helper"

class AutomationMentionFilterTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @superagent = @global_superagent
    @user = @global_user
    @tenant.set_feature_flag!("ai_agents", true)
    Superagent.scope_thread_to_superagent(
      subdomain: @tenant.subdomain,
      handle: @superagent.handle
    )

    # Create an AI agent for testing (parent is required)
    # Adding to tenant creates the TenantUser record with a handle
    @ai_agent = create_ai_agent(parent: @user, name: "Test Agent")
    @tenant.add_user!(@ai_agent)
    @superagent.add_user!(@ai_agent)
  end

  # === No Filter (blank) ===

  test "matches returns true when mention_filter is nil" do
    note = create_note(text: "Hello world")
    event = create_event_for_note(note)

    assert AutomationMentionFilter.matches?(event, @ai_agent, nil)
  end

  test "matches returns true when mention_filter is empty string" do
    note = create_note(text: "Hello world")
    event = create_event_for_note(note)

    assert AutomationMentionFilter.matches?(event, @ai_agent, "")
  end

  # === Self Filter ===

  test "self filter matches when agent is mentioned in note" do
    handle = agent_handle(@ai_agent)
    note = create_note(text: "Hey @#{handle}, what do you think?")
    event = create_event_for_note(note)

    assert AutomationMentionFilter.matches?(event, @ai_agent, "self")
  end

  test "self filter does not match when agent is not mentioned" do
    note = create_note(text: "Hello everyone!")
    event = create_event_for_note(note)

    assert_not AutomationMentionFilter.matches?(event, @ai_agent, "self")
  end

  test "self filter does not match when different user is mentioned" do
    other_user = create_user(name: "Other User")
    @tenant.add_user!(other_user)
    @superagent.add_user!(other_user)
    other_handle = agent_handle(other_user)

    note = create_note(text: "Hey @#{other_handle}, what do you think?")
    event = create_event_for_note(note)

    assert_not AutomationMentionFilter.matches?(event, @ai_agent, "self")
  end

  test "self filter matches when agent is one of multiple mentions" do
    other_user = create_user(name: "Other User")
    @tenant.add_user!(other_user)
    @superagent.add_user!(other_user)
    other_handle = agent_handle(other_user)
    agent_handle_str = agent_handle(@ai_agent)

    note = create_note(text: "Hey @#{other_handle} and @#{agent_handle_str}!")
    event = create_event_for_note(note)

    assert AutomationMentionFilter.matches?(event, @ai_agent, "self")
  end

  # === Any Agent Filter ===

  test "any_agent filter matches when the specific agent is mentioned" do
    handle = agent_handle(@ai_agent)
    note = create_note(text: "Hey @#{handle}!")
    event = create_event_for_note(note)

    assert AutomationMentionFilter.matches?(event, @ai_agent, "any_agent")
  end

  test "any_agent filter matches when a different agent is mentioned" do
    other_agent = create_ai_agent(parent: @user, name: "Other Agent")
    @tenant.add_user!(other_agent)
    @superagent.add_user!(other_agent)
    other_handle = agent_handle(other_agent)

    note = create_note(text: "Hey @#{other_handle}!")
    event = create_event_for_note(note)

    assert AutomationMentionFilter.matches?(event, @ai_agent, "any_agent")
  end

  test "any_agent filter does not match when only human user is mentioned" do
    human_user = create_user(name: "Human User")
    @tenant.add_user!(human_user)
    @superagent.add_user!(human_user)
    human_handle = agent_handle(human_user)

    note = create_note(text: "Hey @#{human_handle}!")
    event = create_event_for_note(note)

    assert_not AutomationMentionFilter.matches?(event, @ai_agent, "any_agent")
  end

  test "any_agent filter does not match when no one is mentioned" do
    note = create_note(text: "Hello everyone!")
    event = create_event_for_note(note)

    assert_not AutomationMentionFilter.matches?(event, @ai_agent, "any_agent")
  end

  # === Unknown Filter ===

  test "unknown filter type returns false" do
    handle = agent_handle(@ai_agent)
    note = create_note(text: "Hey @#{handle}!")
    event = create_event_for_note(note)

    assert_not AutomationMentionFilter.matches?(event, @ai_agent, "unknown_filter")
  end

  # === Different Subject Types ===

  test "extracts mentions from decision question" do
    handle = agent_handle(@ai_agent)
    decision = create_decision(question: "What does @#{handle} think?")
    event = Event.create!(
      tenant: @tenant,
      superagent: @superagent,
      event_type: "decision.created",
      actor: @user,
      subject: decision
    )

    assert AutomationMentionFilter.matches?(event, @ai_agent, "self")
  end

  test "extracts mentions from decision description" do
    handle = agent_handle(@ai_agent)
    decision = create_decision(
      question: "What should we do?",
      description: "Let's ask @#{handle} for input."
    )
    event = Event.create!(
      tenant: @tenant,
      superagent: @superagent,
      event_type: "decision.created",
      actor: @user,
      subject: decision
    )

    assert AutomationMentionFilter.matches?(event, @ai_agent, "self")
  end

  test "extracts mentions from commitment title" do
    handle = agent_handle(@ai_agent)
    commitment = create_commitment(title: "Review with @#{handle}")
    event = Event.create!(
      tenant: @tenant,
      superagent: @superagent,
      event_type: "commitment.created",
      actor: @user,
      subject: commitment
    )

    assert AutomationMentionFilter.matches?(event, @ai_agent, "self")
  end

  test "extracts mentions from commitment description" do
    handle = agent_handle(@ai_agent)
    commitment = create_commitment(
      title: "Weekly review",
      description: "Coordinated by @#{handle}"
    )
    event = Event.create!(
      tenant: @tenant,
      superagent: @superagent,
      event_type: "commitment.created",
      actor: @user,
      subject: commitment
    )

    assert AutomationMentionFilter.matches?(event, @ai_agent, "self")
  end

  # === Edge Cases ===

  test "handles nil subject gracefully" do
    event = Event.create!(
      tenant: @tenant,
      superagent: @superagent,
      event_type: "test.event",
      actor: @user,
      subject: nil
    )

    assert_not AutomationMentionFilter.matches?(event, @ai_agent, "self")
  end

  test "handles subject with empty text" do
    note = create_note(text: "")
    event = create_event_for_note(note)

    assert_not AutomationMentionFilter.matches?(event, @ai_agent, "self")
  end

  test "handles subject with nil text" do
    # Create a note, then set text to nil directly
    note = create_note(text: "temp")
    note.update_column(:text, nil)
    event = create_event_for_note(note)

    assert_not AutomationMentionFilter.matches?(event, @ai_agent, "self")
  end

  test "handles comment on note" do
    handle = agent_handle(@ai_agent)
    parent_note = create_note(text: "Parent content")
    comment = create_note(text: "Comment mentioning @#{handle}", commentable: parent_note)

    event = Event.create!(
      tenant: @tenant,
      superagent: @superagent,
      event_type: "comment.created",
      actor: @user,
      subject: comment
    )

    assert AutomationMentionFilter.matches?(event, @ai_agent, "self")
  end

  # === Mention Format Variations ===

  test "matches mention at start of text" do
    handle = agent_handle(@ai_agent)
    note = create_note(text: "@#{handle} please review")
    event = create_event_for_note(note)

    assert AutomationMentionFilter.matches?(event, @ai_agent, "self")
  end

  test "matches mention at end of text" do
    handle = agent_handle(@ai_agent)
    note = create_note(text: "Please review @#{handle}")
    event = create_event_for_note(note)

    assert AutomationMentionFilter.matches?(event, @ai_agent, "self")
  end

  test "matches mention in middle of text" do
    handle = agent_handle(@ai_agent)
    note = create_note(text: "I think @#{handle} should review this")
    event = create_event_for_note(note)

    assert AutomationMentionFilter.matches?(event, @ai_agent, "self")
  end

  test "matches multiple mentions of same agent" do
    handle = agent_handle(@ai_agent)
    note = create_note(text: "@#{handle} and @#{handle} again")
    event = create_event_for_note(note)

    assert AutomationMentionFilter.matches?(event, @ai_agent, "self")
  end

  private

  def create_event_for_note(note)
    Event.create!(
      tenant: @tenant,
      superagent: @superagent,
      event_type: "note.created",
      actor: @user,
      subject: note
    )
  end

  def agent_handle(user)
    tenant_user = TenantUser.tenant_scoped_only(@tenant.id).find_by(user_id: user.id)
    tenant_user&.handle
  end
end
