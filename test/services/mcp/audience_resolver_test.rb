# typed: false

require "test_helper"

class Mcp::AudienceResolverTest < ActiveSupport::TestCase
  setup do
    @tenant = @global_tenant
    # @global_collective is non-main; the actual main_collective is what
    # resolves to "public".
    @main_collective = @tenant.main_collective
    @other_collective = @global_collective
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
  end

  teardown do
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  # Architectural invariant: visibility lives on the action definition, not in
  # parallel lists maintained by the resolver. Every entry in ACTION_DEFINITIONS
  # must declare its tier so the codebase can't drift — adding or renaming an
  # action forces the author to think about visibility once, in the same place
  # they declare description / params / authorization.
  test "every action in ACTION_DEFINITIONS declares :visibility" do
    missing = ActionsHelper::ACTION_DEFINITIONS.reject { |_, defn| defn.key?(:visibility) }.keys
    assert missing.empty?,
           "actions missing :visibility (declare :public, :private, :shared, :by_collective, or a Proc): #{missing.inspect}"
  end

  test "every declared :visibility resolves to a valid tier in realistic collective contexts" do
    # :by_collective explicitly raises when given no collective (see the
    # dedicated test below), so we only iterate over realistic contexts here.
    ActionsHelper::ACTION_DEFINITIONS.each do |name, defn|
      next unless defn.key?(:visibility)

      [@main_collective, @other_collective].each do |coll|
        tier = Mcp::AudienceResolver.resolve(capability_action: name, collective: coll)
        assert_includes %w[public private shared], tier,
                        "#{name}: visibility #{defn[:visibility].inspect} produced invalid tier #{tier.inspect}"
      end
    end
  end

  # --- :by_collective resolution ---

  test ":by_collective + main collective resolves to public" do
    assert_equal "public", Mcp::AudienceResolver.resolve(capability_action: "create_note", collective: @main_collective)
  end

  test ":by_collective + non-main collective resolves to shared" do
    assert_equal "shared", Mcp::AudienceResolver.resolve(capability_action: "create_note", collective: @other_collective)
  end

  test ":by_collective + no collective raises (caller is misconfigured)" do
    # An action declared :by_collective is intrinsically collective-scoped —
    # if there's no collective in context, something upstream is wrong.
    # Fail loud so the bug surfaces instead of silently picking a tier.
    assert_raises(ArgumentError) do
      Mcp::AudienceResolver.resolve(capability_action: "create_note", collective: nil)
    end
  end

  test ":by_collective + private workspace resolves to private" do
    # A private workspace collective is scoped to a single user — content
    # there is only visible to them — so any :by_collective action landing
    # on a workspace must resolve to `private`, not `shared`. Without this,
    # writes to the agent's own workspace would be tiered as if they were
    # group-visible.
    workspace = Collective.create!(
      tenant: @tenant,
      created_by: @global_user,
      name: "Test Workspace",
      handle: "test-workspace-#{SecureRandom.hex(2)}",
      collective_type: "private_workspace"
    )
    assert_equal "private", Mcp::AudienceResolver.resolve(capability_action: "create_note", collective: workspace)
  end

  # --- Full visibility mapping lock-in ---
  #
  # Anti-drift: pin every action's tier. Any future change to ACTION_DEFINITIONS
  # that alters a visibility value also has to update this expected mapping —
  # which forces the author to think about audience exposure deliberately and
  # invites code review on the change.
  #
  # When you intentionally change an action's tier, update the expected value
  # here in the same diff. When you add a new action, add it here.
  EXPECTED_VISIBILITY = {
    # :public — broadest tenant audience (visible to anyone on the site)
    "create_collective" => :public,
    "create_ai_agent" => :public,
    "create_tenant" => :public,
    "update_tenant_settings" => :public,
    "update_profile" => :public,
    "tune_in" => :public,
    "tune_out" => :public,
    # :public placeholder for user_list actions — each list carries its own
    # public/private setting; the action's tier should follow that setting,
    # but until we model per-list visibility this stays as a conservative
    # default. See the TODO comments in ACTION_DEFINITIONS.
    "create_user_list" => :public,
    "update_user_list" => :public,
    "delete_user_list" => :public,
    "add_member_to_list" => :public,
    "join_list" => :public,
    "remove_member_from_list" => :public,

    # :private — only the acting agent sees it
    "update_scratchpad" => :private,
    "create_api_token" => :private,
    "retry_sidekiq_job" => :private,
    "dismiss" => :private,
    "dismiss_all" => :private,
    "dismiss_for_collective" => :private,
    "dismiss_for_chat" => :private,
    "mark_read" => :private,
    "mark_all_read" => :private,
    "mark_read_for_collective" => :private,

    # :shared — a specific group/relationship, not a public audience
    "join_collective" => :shared,
    "send_message" => :shared,
    "report_content" => :shared,
    "suspend_user" => :shared,
    "unsuspend_user" => :shared,
    "toggle_billing_exempt" => :shared,
    "create_trustee_grant" => :shared,
    "accept_trustee_grant" => :shared,
    "decline_trustee_grant" => :shared,
    "revoke_trustee_grant" => :shared,
    "start_representation" => :shared,
    "end_representation" => :shared,

    # :by_collective — tier follows the collective (public/shared/private workspace)
    "update_collective_settings" => :by_collective,
    "add_ai_agent_to_collective" => :by_collective,
    "remove_ai_agent_from_collective" => :by_collective,
    "send_heartbeat" => :by_collective,
    "create_note" => :by_collective,
    "update_note" => :by_collective,
    "confirm_read" => :by_collective,
    "create_reminder_note" => :by_collective,
    "cancel_reminder" => :by_collective,
    "acknowledge_reminder" => :by_collective,
    "create_table_note" => :by_collective,
    "add_row" => :by_collective,
    "update_row" => :by_collective,
    "delete_row" => :by_collective,
    "add_table_column" => :by_collective,
    "remove_table_column" => :by_collective,
    "query_rows" => :by_collective,
    "summarize" => :by_collective,
    "update_table_description" => :by_collective,
    "batch_table_update" => :by_collective,
    "pin_note" => :by_collective,
    "unpin_note" => :by_collective,
    "delete_note" => :by_collective,
    "create_decision" => :by_collective,
    "update_decision_settings" => :by_collective,
    "add_options" => :by_collective,
    "vote" => :by_collective,
    "pin_decision" => :by_collective,
    "unpin_decision" => :by_collective,
    "close_decision" => :by_collective,
    "add_statement" => :by_collective,
    "delete_decision" => :by_collective,
    "create_commitment" => :by_collective,
    "update_commitment_settings" => :by_collective,
    "join_commitment" => :by_collective,
    "pin_commitment" => :by_collective,
    "unpin_commitment" => :by_collective,
    "delete_commitment" => :by_collective,
    "add_comment" => :by_collective,
    "add_attachment" => :by_collective,
    "remove_attachment" => :by_collective,
    "search" => :by_collective,
    "create_webhook" => :by_collective,
    "update_webhook" => :by_collective,
    "delete_webhook" => :by_collective,
    "test_webhook" => :by_collective,
    "create_automation_rule" => :by_collective,
    "update_automation_rule" => :by_collective,
    "delete_automation_rule" => :by_collective,
    "toggle_automation_rule" => :by_collective,
  }.freeze

  test "every action's declared :visibility matches the expected lock-in mapping" do
    actual = ActionsHelper::ACTION_DEFINITIONS.transform_values { |defn| defn[:visibility] }
    assert_equal EXPECTED_VISIBILITY.sort.to_h, actual.sort.to_h,
                 "ACTION_DEFINITIONS visibility drifted from the expected lock-in. " \
                 "Update EXPECTED_VISIBILITY in this test only when the tier change is intentional."
  end

  # --- Canonical tier categories (spot-checks against the live ACTION_DEFINITIONS) ---

  test "notification actions all resolve to :private" do
    # The bug that motivated putting visibility on the action definition: new
    # notification actions used to inherit the wrong tier when added without
    # updating a parallel allowlist. Locking these in keeps that drift from
    # returning.
    %w[dismiss dismiss_all dismiss_for_collective dismiss_for_chat mark_read mark_all_read mark_read_for_collective].each do |action|
      assert_equal "private", Mcp::AudienceResolver.resolve(capability_action: action, collective: nil),
                   "expected #{action} to be private"
    end
  end

  test "update_scratchpad resolves to :private" do
    assert_equal "private", Mcp::AudienceResolver.resolve(capability_action: "update_scratchpad", collective: nil)
  end

  test "send_message resolves to :shared regardless of collective" do
    assert_equal "shared", Mcp::AudienceResolver.resolve(capability_action: "send_message", collective: @main_collective)
    assert_equal "shared", Mcp::AudienceResolver.resolve(capability_action: "send_message", collective: @other_collective)
  end

  # --- Fallback behavior ---

  test "nil capability_action with a main collective falls back to by-collective (public)" do
    assert_equal "public", Mcp::AudienceResolver.resolve(capability_action: nil, collective: @main_collective)
  end

  test "nil capability_action with no collective raises" do
    # Nil action falls through to :by_collective, which itself raises without
    # a collective. The caller has supplied nothing for the resolver to work
    # with — fail loud.
    assert_raises(ArgumentError) do
      Mcp::AudienceResolver.resolve(capability_action: nil, collective: nil)
    end
  end

  test "unknown capability_action falls back to by-collective" do
    # Actions reached via routes outside ACTION_DEFINITIONS (e.g. legacy or
    # ad-hoc) fall back to the collective tier — safe default for the
    # common case.
    assert_equal "public", Mcp::AudienceResolver.resolve(capability_action: "unknown_made_up_action", collective: @main_collective)
    assert_equal "shared", Mcp::AudienceResolver.resolve(capability_action: "unknown_made_up_action", collective: @other_collective)
  end

  # --- Invalid configuration loudly fails ---

  test "raises when an action's :visibility is an unknown symbol" do
    ActionsHelper.stub(:action_definition, ->(_) { { visibility: :nope } }) do
      assert_raises(ArgumentError) do
        Mcp::AudienceResolver.resolve(capability_action: "x", collective: @main_collective)
      end
    end
  end
end
