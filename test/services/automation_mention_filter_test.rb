# typed: false

require "test_helper"

class AutomationMentionFilterTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    @tenant.set_feature_flag!("internal_ai_agents", true)
    @tenant.set_feature_flag!("external_ai_agents", true)
    Collective.scope_thread_to_collective(
      subdomain: @tenant.subdomain,
      handle: @collective.handle
    )

    # Create an AI agent for testing (parent is required)
    # Adding to tenant creates the TenantUser record with a handle
    @ai_agent = create_ai_agent(parent: @user, name: "Test Agent")
    @tenant.add_user!(@ai_agent)
    @collective.add_user!(@ai_agent)
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
    @collective.add_user!(other_user)
    other_handle = agent_handle(other_user)

    note = create_note(text: "Hey @#{other_handle}, what do you think?")
    event = create_event_for_note(note)

    assert_not AutomationMentionFilter.matches?(event, @ai_agent, "self")
  end

  test "self filter matches when agent is one of multiple mentions" do
    other_user = create_user(name: "Other User")
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)
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
    @collective.add_user!(other_agent)
    other_handle = agent_handle(other_agent)

    note = create_note(text: "Hey @#{other_handle}!")
    event = create_event_for_note(note)

    assert AutomationMentionFilter.matches?(event, @ai_agent, "any_agent")
  end

  test "any_agent filter does not match when only human user is mentioned" do
    human_user = create_user(name: "Human User")
    @tenant.add_user!(human_user)
    @collective.add_user!(human_user)
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

  # === self_or_reply Filter ===

  test "self_or_reply filter matches when agent is mentioned" do
    handle = agent_handle(@ai_agent)
    note = create_note(text: "Hey @#{handle}, what do you think?")
    event = create_event_for_note(note)

    assert AutomationMentionFilter.matches?(event, @ai_agent, "self_or_reply")
  end

  test "self_or_reply filter matches when the event subject is a reply to a note the agent authored" do
    agent_note = create_note(text: "My note", created_by: @ai_agent)
    reply = create_note(text: "Thanks!", commentable: agent_note)
    event = create_event_for_note(reply)

    assert AutomationMentionFilter.matches?(event, @ai_agent, "self_or_reply")
  end

  test "self_or_reply filter does not match when the reply is to a note authored by someone else" do
    other_note = create_note(text: "Someone else's note", created_by: @user)
    reply = create_note(text: "Cool", commentable: other_note)
    event = create_event_for_note(reply)

    assert_not AutomationMentionFilter.matches?(event, @ai_agent, "self_or_reply")
  end

  test "self_or_reply filter does not match a top-level note that doesn't mention the agent" do
    note = create_note(text: "Just a normal note, no mention.")
    event = create_event_for_note(note)

    assert_not AutomationMentionFilter.matches?(event, @ai_agent, "self_or_reply")
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
      collective: @collective,
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
      collective: @collective,
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
      collective: @collective,
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
      collective: @collective,
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
      collective: @collective,
      event_type: "test.event",
      actor: @user,
      subject: nil
    )

    assert_not AutomationMentionFilter.matches?(event, @ai_agent, "self")
  end

  test "handles subject with empty text" do
    note = create_note(text: "temp")
    note.update_column(:text, "")
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
      collective: @collective,
      event_type: "comment.created",
      actor: @user,
      subject: comment
    )

    assert AutomationMentionFilter.matches?(event, @ai_agent, "self")
  end

  # === @trio (per-collective system agent) ===

  test "self filter matches when @trio is mentioned and agent is the collective's trio_user" do
    trio = User.create!(
      email: "trio_#{SecureRandom.hex(4)}@system.harmonic.local",
      name: "Trio", user_type: "ai_agent", system_role: "trio", parent_id: nil,
    )
    # Trio's stored handle is intentionally non-"trio" (random hex). The literal
    # string @trio is resolved by the MentionParser via collective.trio_user, so
    # the handle index never collides across collectives.
    @tenant.add_user!(trio, handle: "trio-#{SecureRandom.hex(4)}")
    @collective.add_user!(trio)
    @collective.update!(trio_user: trio)

    note = create_note(text: "Hey @trio, what should we do?")
    event = create_event_for_note(note)

    assert AutomationMentionFilter.matches?(event, trio, "self")
  end

  test "self filter does not match @trio when agent is a different collective's trio" do
    other_collective = create_collective(tenant: @tenant, created_by: @user, handle: "other-#{SecureRandom.hex(4)}")
    other_trio = User.create!(
      email: "trio_other_#{SecureRandom.hex(4)}@system.harmonic.local",
      name: "Trio", user_type: "ai_agent", system_role: "trio", parent_id: nil,
    )
    @tenant.add_user!(other_trio, handle: "trio-#{SecureRandom.hex(4)}")
    other_collective.add_user!(other_trio)
    other_collective.update!(trio_user: other_trio)

    note = create_note(text: "Hey @trio")
    event = create_event_for_note(note)

    # Event is in @collective, not other_collective — so other_collective's trio
    # is not in scope here.
    assert_not AutomationMentionFilter.matches?(event, other_trio, "self")
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
      collective: @collective,
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
