# frozen_string_literal: true

require "test_helper"

class AddSummaryActionTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    @note = Note.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      updated_by: @user,
      text: "Long thread that needs a summary",
      subtype: "post"
    )

    @decision = Decision.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      question: "Test?",
      description: "A test decision",
      deadline: 1.week.from_now
    )

    @commitment = Commitment.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      title: "Test Commitment",
      description: "A test commitment",
      critical_mass: 5,
      deadline: 1.week.from_now
    )

    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  # === Notes ===

  test "signed-in user can add a summary to a note" do
    sign_in_as(@user, tenant: @tenant)

    assert_difference -> { Note.where(subtype: "summary", summarizable: @note).count }, 1 do
      post "/collectives/#{@collective.handle}/n/#{@note.truncated_id}/actions/add_summary",
           params: { text: "TL;DR of the thread." }
    end

    summary = @note.reload.summary
    assert_equal "TL;DR of the thread.", summary.text
    assert_equal "summary", summary.subtype
    assert_equal @user.id, summary.created_by_id
    assert_response :redirect
  end

  test "unauthenticated user cannot add a summary to a note" do
    assert_no_difference -> { Note.where(subtype: "summary", summarizable: @note).count } do
      post "/collectives/#{@collective.handle}/n/#{@note.truncated_id}/actions/add_summary",
           params: { text: "Should not save." }
    end
  end

  test "second add_summary updates the existing summary" do
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/n/#{@note.truncated_id}/actions/add_summary",
         params: { text: "First take." }
    post "/collectives/#{@collective.handle}/n/#{@note.truncated_id}/actions/add_summary",
         params: { text: "Second take." }

    summaries = Note.where(subtype: "summary", summarizable: @note)
    assert_equal 1, summaries.count
    assert_equal "Second take.", summaries.first.text
  end

  test "describe add_summary on note responds for signed-in user" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/n/#{@note.truncated_id}/actions/add_summary"
    assert_response :success
  end

  # === Decisions ===

  test "signed-in user can add a summary to a decision" do
    sign_in_as(@user, tenant: @tenant)

    assert_difference -> { Note.where(subtype: "summary", summarizable: @decision).count }, 1 do
      post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/actions/add_summary",
           params: { text: "Summary of the discussion." }
    end

    summary = @decision.reload.summary
    assert_equal "Summary of the discussion.", summary.text
    assert_equal "summary", summary.subtype
    assert_response :redirect
  end

  test "unauthenticated user cannot add a summary to a decision" do
    assert_no_difference -> { Note.where(subtype: "summary", summarizable: @decision).count } do
      post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/actions/add_summary",
           params: { text: "Should not save." }
    end
  end

  test "describe add_summary on decision responds for signed-in user" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/actions/add_summary"
    assert_response :success
  end

  # === Commitments ===

  test "signed-in user can add a summary to a commitment" do
    sign_in_as(@user, tenant: @tenant)

    assert_difference -> { Note.where(subtype: "summary", summarizable: @commitment).count }, 1 do
      post "/collectives/#{@collective.handle}/c/#{@commitment.truncated_id}/actions/add_summary",
           params: { text: "Summary of the commitment." }
    end

    summary = @commitment.reload.summary
    assert_equal "Summary of the commitment.", summary.text
    assert_equal "summary", summary.subtype
    assert_response :redirect
  end

  test "unauthenticated user cannot add a summary to a commitment" do
    assert_no_difference -> { Note.where(subtype: "summary", summarizable: @commitment).count } do
      post "/collectives/#{@collective.handle}/c/#{@commitment.truncated_id}/actions/add_summary",
           params: { text: "Should not save." }
    end
  end

  test "describe add_summary on commitment responds for signed-in user" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/c/#{@commitment.truncated_id}/actions/add_summary"
    assert_response :success
  end

  # === Markdown format ===

  test "markdown response on add_summary success returns structured action result" do
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/actions/add_summary.md",
         params: { text: "Summary of the discussion." }

    assert_response :success
    assert_match(/add_summary/, response.body)
  end

  # === Display ===

  test "decision markdown view renders summary section" do
    sign_in_as(@user, tenant: @tenant)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    Note.create!(
      subtype: "summary", text: "A summary.",
      summarizable: @decision, created_by: @user, updated_by: @user,
      tenant: @tenant, collective: @collective, deadline: Time.current, edit_access: "owner"
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}.md"
    assert_response :success
    assert_match(/## \[Summary\]/, response.body)
    assert_match(/A summary\./, response.body)
  end

  test "note markdown view renders summary section" do
    sign_in_as(@user, tenant: @tenant)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    Note.create!(
      subtype: "summary", text: "Thread summary.",
      summarizable: @note, created_by: @user, updated_by: @user,
      tenant: @tenant, collective: @collective, deadline: Time.current, edit_access: "owner"
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/n/#{@note.truncated_id}.md"
    assert_response :success
    assert_match(/## \[Summary\]/, response.body)
    assert_match(/Thread summary\./, response.body)
  end

  test "commitment markdown view renders summary section" do
    sign_in_as(@user, tenant: @tenant)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    Note.create!(
      subtype: "summary", text: "Commitment summary.",
      summarizable: @commitment, created_by: @user, updated_by: @user,
      tenant: @tenant, collective: @collective, deadline: Time.current, edit_access: "owner"
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/c/#{@commitment.truncated_id}.md"
    assert_response :success
    assert_match(/## \[Summary\]/, response.body)
    assert_match(/Commitment summary\./, response.body)
  end

  test "markdown view omits summary section when none exists" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}.md"
    assert_response :success
    assert_no_match(/## \[Summary\]/, response.body)
  end

  # === Summaries cannot summarize summaries ===

  test "cannot create a summary of a summary note" do
    sign_in_as(@user, tenant: @tenant)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    summary_note = Note.create!(
      subtype: "summary", text: "The summary itself.",
      summarizable: @note, created_by: @user, updated_by: @user,
      tenant: @tenant, collective: @collective, deadline: Time.current, edit_access: "owner"
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    assert_no_difference -> { Note.where(subtype: "summary", summarizable: summary_note).count } do
      post "/collectives/#{@collective.handle}/n/#{summary_note.truncated_id}/actions/add_summary",
           params: { text: "Meta-summary." }
    end
  end

  test "markdown action list omits add_summary for a summary note" do
    sign_in_as(@user, tenant: @tenant)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    summary_note = Note.create!(
      subtype: "summary", text: "The summary itself.",
      summarizable: @note, created_by: @user, updated_by: @user,
      tenant: @tenant, collective: @collective, deadline: Time.current, edit_access: "owner"
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/n/#{summary_note.truncated_id}.md"
    assert_response :success
    assert_no_match(/add_summary/, response.body)

    get "/collectives/#{@collective.handle}/n/#{@note.truncated_id}.md"
    assert_response :success
    assert_match(/add_summary/, response.body)
  end

  test "markdown view of a summary note links back to its parent and omits the summary section" do
    sign_in_as(@user, tenant: @tenant)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    summary_note = Note.create!(
      subtype: "summary", text: "The summary itself.",
      summarizable: @note, created_by: @user, updated_by: @user,
      tenant: @tenant, collective: @collective, deadline: Time.current, edit_access: "owner"
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/n/#{summary_note.truncated_id}.md"
    assert_response :success
    assert_match(/Summary of Note \[#{@note.truncated_id}\]/, response.body)
    assert_no_match(/## \[Summary\]/, response.body)
  end

  test "html show page omits summary form for a summary note" do
    sign_in_as(@user, tenant: @tenant)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    summary_note = Note.create!(
      subtype: "summary", text: "The summary itself.",
      summarizable: @note, created_by: @user, updated_by: @user,
      tenant: @tenant, collective: @collective, deadline: Time.current, edit_access: "owner"
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/n/#{summary_note.truncated_id}"
    assert_response :success
    assert_select "form[action*='/actions/add_summary']", count: 0
  end
end
