# frozen_string_literal: true

require "test_helper"

class Mcp::ContextResourceTest < ActiveSupport::TestCase
  setup do
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    @agent = create_ai_agent(
      parent: @user,
      name: "Context Test Agent",
      agent_configuration: {
        "mode" => "external",
        "identity_prompt" => "You are a research assistant. Help your principal investigate ideas.",
      },
    )
    @tenant.add_user!(@agent)
    @collective.add_user!(@agent)
  end

  teardown do
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  test "returns a markdown string with a personalized header" do
    text = Mcp::ContextResource.render(@agent)
    assert_kind_of String, text
    assert_includes text, "# Harmonic context"
    assert_includes text, @agent.handle.to_s
  end

  test "includes the agent's display name" do
    text = Mcp::ContextResource.render(@agent)
    assert_includes text, @agent.display_name.to_s
  end

  test "includes the principal's handle and display name" do
    text = Mcp::ContextResource.render(@agent)
    assert_includes text, @user.handle.to_s
    assert_includes text, @user.display_name.to_s
  end

  test "links to the getting-started doc" do
    text = Mcp::ContextResource.render(@agent)
    assert_includes text, "/help/agents/getting-started"
  end

  test "includes the identity prompt when set" do
    text = Mcp::ContextResource.render(@agent)
    assert_includes text, "Your identity prompt"
    assert_includes text, "You are a research assistant"
  end

  test "omits the identity-prompt section when blank" do
    @agent.update!(agent_configuration: @agent.agent_configuration.merge("identity_prompt" => ""))
    text = Mcp::ContextResource.render(@agent)
    refute_includes text, "Your identity prompt"
  end

  test "truncates a very long identity prompt" do
    long_prompt = "x" * 5000
    @agent.update!(agent_configuration: @agent.agent_configuration.merge("identity_prompt" => long_prompt))
    text = Mcp::ContextResource.render(@agent)
    refute_includes text, "x" * 2000, "Expected truncation; full 5000-char prompt should not appear"
    assert_includes text, "x" * 100, "Expected at least the beginning of the prompt"
  end

  test "lists the collectives the agent is a member of (with paths)" do
    text = Mcp::ContextResource.render(@agent)
    assert_includes text, "Your collectives"
    assert_includes text, @collective.path
  end

  test "omits the main collective from the list (it has no path)" do
    main = @tenant.main_collective
    main.add_user!(@agent) unless @agent.collective_members.exists?(collective: main)
    text = Mcp::ContextResource.render(@agent)
    # Main collective entry shouldn't appear because its path is nil.
    refute_match(%r{\[#{Regexp.escape(main.name)}\]}, text)
  end

  test "stays under 8 KiB total" do
    text = Mcp::ContextResource.render(@agent)
    assert text.bytesize < 8 * 1024, "Expected <8 KiB, got #{text.bytesize}"
  end
end
