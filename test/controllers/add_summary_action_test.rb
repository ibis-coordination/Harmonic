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

    @collective.collective_members.find_by(user: @user).add_role!('summarizer')

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

  test "member without summarizer role cannot add a summary" do
    other_user = create_user
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)
    Tenant.clear_thread_scope
    sign_in_as(other_user, tenant: @tenant)

    assert_no_difference -> { Note.where(subtype: "summary", summarizable: @note).count } do
      post "/collectives/#{@collective.handle}/n/#{@note.truncated_id}/actions/add_summary",
           params: { text: "Should not save." }
    end
  end

  test "any member can summarize when collective allows it" do
    other_user = create_user
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)
    @collective.settings['any_member_can_summarize'] = true
    @collective.save!
    Tenant.clear_thread_scope
    sign_in_as(other_user, tenant: @tenant)

    assert_difference -> { Note.where(subtype: "summary", summarizable: @note).count }, 1 do
      post "/collectives/#{@collective.handle}/n/#{@note.truncated_id}/actions/add_summary",
           params: { text: "Open summary." }
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

  test "decision markdown view links to the summary without inlining its content" do
    sign_in_as(@user, tenant: @tenant)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    summary = Note.create!(
      subtype: "summary", text: "Secret summary text that must not appear on the parent.",
      summarizable: @decision, created_by: @user, updated_by: @user,
      tenant: @tenant, collective: @collective, deadline: Time.current, edit_access: "owner"
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}.md"
    assert_response :success
    assert_match(/## Summary/, response.body)
    assert_match(/#{Regexp.escape(summary.path)}/, response.body)
    assert_no_match(/Secret summary text/, response.body)
  end

  test "note markdown view links to the summary without inlining its content" do
    sign_in_as(@user, tenant: @tenant)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    summary = Note.create!(
      subtype: "summary", text: "Secret thread summary text.",
      summarizable: @note, created_by: @user, updated_by: @user,
      tenant: @tenant, collective: @collective, deadline: Time.current, edit_access: "owner"
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/n/#{@note.truncated_id}.md"
    assert_response :success
    assert_match(/## Summary/, response.body)
    assert_match(/#{Regexp.escape(summary.path)}/, response.body)
    assert_no_match(/Secret thread summary text/, response.body)
  end

  test "commitment markdown view links to the summary without inlining its content" do
    sign_in_as(@user, tenant: @tenant)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    summary = Note.create!(
      subtype: "summary", text: "Secret commitment summary text.",
      summarizable: @commitment, created_by: @user, updated_by: @user,
      tenant: @tenant, collective: @collective, deadline: Time.current, edit_access: "owner"
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/c/#{@commitment.truncated_id}.md"
    assert_response :success
    assert_match(/## Summary/, response.body)
    assert_match(/#{Regexp.escape(summary.path)}/, response.body)
    assert_no_match(/Secret commitment summary text/, response.body)
  end

  test "markdown view omits summary section when none exists" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}.md"
    assert_response :success
    assert_no_match(/## Summary/, response.body)
  end

  test "summary's own markdown show page includes its full text content" do
    sign_in_as(@user, tenant: @tenant)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    summary = Note.create!(
      subtype: "summary", text: "Full summary content lives only here.",
      summarizable: @decision, created_by: @user, updated_by: @user,
      tenant: @tenant, collective: @collective, deadline: Time.current, edit_access: "owner"
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/n/#{summary.truncated_id}.md"
    assert_response :success
    assert_match(/Full summary content lives only here\./, response.body)
  end

  # === Pretty-path summary routes ===

  test "decision summary path serves the summary content in markdown" do
    sign_in_as(@user, tenant: @tenant)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    Note.create!(
      subtype: "summary", text: "Decision summary body.",
      summarizable: @decision, created_by: @user, updated_by: @user,
      tenant: @tenant, collective: @collective, deadline: Time.current, edit_access: "owner"
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/summary.md"
    assert_response :success
    assert_match(/Decision summary body\./, response.body)
  end

  test "note summary path serves the summary content in markdown" do
    sign_in_as(@user, tenant: @tenant)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    Note.create!(
      subtype: "summary", text: "Note thread summary body.",
      summarizable: @note, created_by: @user, updated_by: @user,
      tenant: @tenant, collective: @collective, deadline: Time.current, edit_access: "owner"
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/n/#{@note.truncated_id}/summary.md"
    assert_response :success
    assert_match(/Note thread summary body\./, response.body)
  end

  test "commitment summary path serves the summary content in markdown" do
    sign_in_as(@user, tenant: @tenant)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    Note.create!(
      subtype: "summary", text: "Commitment summary body.",
      summarizable: @commitment, created_by: @user, updated_by: @user,
      tenant: @tenant, collective: @collective, deadline: Time.current, edit_access: "owner"
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/c/#{@commitment.truncated_id}/summary.md"
    assert_response :success
    assert_match(/Commitment summary body\./, response.body)
  end

  test "summary path returns no-summary page when none exists for a summarizer" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/summary.md"
    assert_response :success
    assert_match(/No summary has been written/, response.body)
    assert_match(/summarizer/, response.body)
    assert_match(%r{#{Regexp.escape(@decision.path)}/actions/add_summary}, response.body)
  end

  test "summary path no-summary page for a non-summarizer points at requesting one" do
    other_user = create_user
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)
    Tenant.clear_thread_scope
    sign_in_as(other_user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/summary.md"
    assert_response :success
    assert_match(/No summary has been written/, response.body)
    assert_match(/Ask a summarizer/, response.body)
  end

  test "summary path html no-summary page renders 200 with add-summary form for a summarizer" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/summary"
    assert_response :success
    assert_match(/No summary has been written/, response.body)
    assert_select "form[action*='/actions/add_summary']"
  end

  test "summary path serves the summary content as html" do
    sign_in_as(@user, tenant: @tenant)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    Note.create!(
      subtype: "summary", text: "Decision summary html body.",
      summarizable: @decision, created_by: @user, updated_by: @user,
      tenant: @tenant, collective: @collective, deadline: Time.current, edit_access: "owner"
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/summary"
    assert_response :success
    assert_match(/Decision summary html body\./, response.body)
  end

  test "legacy /n/<summary_truncated_id> path still serves the summary" do
    sign_in_as(@user, tenant: @tenant)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    summary = Note.create!(
      subtype: "summary", text: "Legacy URL summary body.",
      summarizable: @decision, created_by: @user, updated_by: @user,
      tenant: @tenant, collective: @collective, deadline: Time.current, edit_access: "owner"
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/n/#{summary.truncated_id}"
    assert_response :success
    assert_match(/Legacy URL summary body\./, response.body)
  end

  test "summary-of-a-summary URL returns 404" do
    sign_in_as(@user, tenant: @tenant)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    summary = Note.create!(
      subtype: "summary", text: "The summary.",
      summarizable: @decision, created_by: @user, updated_by: @user,
      tenant: @tenant, collective: @collective, deadline: Time.current, edit_access: "owner"
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/n/#{summary.truncated_id}/summary"
    assert_response :not_found
  end

  test "anonymous viewer can read no_summary html page on anon-readable tenant" do
    prior_env = ENV.fetch("ANON_READABLE_TENANT_SUBDOMAINS", nil)
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = @tenant.subdomain
    Tenant.reset_anon_readable_subdomains!
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    main_collective = @tenant.main_collective
    decision = Decision.create!(
      tenant: @tenant, collective: main_collective, created_by: @user,
      question: "Public?", description: "A public decision", deadline: 1.week.from_now
    )
    Tenant.clear_thread_scope

    host! "#{@tenant.subdomain}.#{ENV.fetch('HOSTNAME', nil)}"
    get "/d/#{decision.truncated_id}/summary"
    assert_response :success
    assert_match(/No summary has been written/, response.body)
    assert_match(/Ask a summarizer/, response.body)
  ensure
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = prior_env
    Tenant.reset_anon_readable_subdomains!
  end

  test "anonymous viewer can read no_summary markdown page on anon-readable tenant" do
    prior_env = ENV.fetch("ANON_READABLE_TENANT_SUBDOMAINS", nil)
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = @tenant.subdomain
    Tenant.reset_anon_readable_subdomains!
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    main_collective = @tenant.main_collective
    decision = Decision.create!(
      tenant: @tenant, collective: main_collective, created_by: @user,
      question: "Public?", description: "A public decision", deadline: 1.week.from_now
    )
    Tenant.clear_thread_scope

    host! "#{@tenant.subdomain}.#{ENV.fetch('HOSTNAME', nil)}"
    get "/d/#{decision.truncated_id}/summary.md"
    assert_response :success
    assert_match(/No summary has been written/, response.body)
    assert_match(/Ask a summarizer/, response.body)
  ensure
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = prior_env
    Tenant.reset_anon_readable_subdomains!
  end

  test "summary path returns Note#path canonical form" do
    sign_in_as(@user, tenant: @tenant)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    summary = Note.create!(
      subtype: "summary", text: "Canonical path summary.",
      summarizable: @decision, created_by: @user, updated_by: @user,
      tenant: @tenant, collective: @collective, deadline: Time.current, edit_access: "owner"
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    assert_equal "#{@decision.path}/summary", summary.path
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

  test "markdown action list omits add_summary for members without the summarizer role" do
    other_user = create_user
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)
    Tenant.clear_thread_scope
    sign_in_as(other_user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/n/#{@note.truncated_id}.md"
    assert_response :success
    assert_no_match(/add_summary/, response.body)

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}.md"
    assert_response :success
    assert_no_match(/add_summary/, response.body)

    get "/collectives/#{@collective.handle}/c/#{@commitment.truncated_id}.md"
    assert_response :success
    assert_no_match(/add_summary/, response.body)
  end

  test "markdown action list includes add_summary for the summarizer member" do
    sign_in_as(@user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/n/#{@note.truncated_id}.md"
    assert_response :success
    assert_match(/add_summary/, response.body)

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}.md"
    assert_response :success
    assert_match(/add_summary/, response.body)

    get "/collectives/#{@collective.handle}/c/#{@commitment.truncated_id}.md"
    assert_response :success
    assert_match(/add_summary/, response.body)
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
    assert_no_match(/## Summary/, response.body)
  end

  test "html show page renders the summary section hidden by default with targets wired" do
    sign_in_as(@user, tenant: @tenant)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    Note.create!(
      subtype: "summary", text: "Hidden until revealed.",
      summarizable: @decision, created_by: @user, updated_by: @user,
      tenant: @tenant, collective: @collective, deadline: Time.current, edit_access: "owner"
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}"
    assert_response :success
    assert_select "[data-summary-toggle-target='section'][hidden]"
    assert_select "[data-summary-toggle-target='embed'][hidden]"
    assert_select "[data-summary-toggle-target='form'][hidden]"
    assert_select "a[data-action*='summary-toggle#showEmbed']", text: /View summary/
    assert_select "a[data-action*='summary-toggle#showForm']", text: /Edit summary/
  end

  test "html show page hides view-summary kebab item when no summary exists" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}"
    assert_response :success
    assert_select "a[data-action*='summary-toggle#showEmbed']", count: 0
    assert_select "a[data-action*='summary-toggle#showForm']", text: /Add summary/
  end

  test "html show page hides add-summary kebab item for members without the summarizer role" do
    other_user = create_user
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)
    Tenant.clear_thread_scope
    sign_in_as(other_user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}"
    assert_response :success
    assert_select "a[data-action*='summary-toggle#showForm']", count: 0
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
