require "test_helper"

class SummarizableTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
  end

  test "Note includes Summarizable and exposes summary" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user, text: "Long thread")
    assert_respond_to note, :summary
    assert_nil note.summary

    summary = Note.create!(
      subtype: "summary",
      text: "TL;DR of the thread",
      summarizable: note,
      created_by: @user,
      updated_by: @user,
      tenant: @tenant,
      collective: @collective,
      deadline: Time.current
    )

    assert_equal summary, note.reload.summary
  end

  test "Decision includes Summarizable and exposes summary" do
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    assert_respond_to decision, :summary

    summary = Note.create!(
      subtype: "summary",
      text: "Decision summary",
      summarizable: decision,
      created_by: @user,
      updated_by: @user,
      tenant: @tenant,
      collective: @collective,
      deadline: Time.current
    )

    assert_equal summary, decision.reload.summary
  end

  test "Commitment includes Summarizable and exposes summary" do
    commitment = create_commitment(tenant: @tenant, collective: @collective, created_by: @user)
    assert_respond_to commitment, :summary

    summary = Note.create!(
      subtype: "summary",
      text: "Commitment summary",
      summarizable: commitment,
      created_by: @user,
      updated_by: @user,
      tenant: @tenant,
      collective: @collective,
      deadline: Time.current
    )

    assert_equal summary, commitment.reload.summary
  end

  test "summary association is scoped to summary subtype only" do
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)

    Note.create!(
      subtype: "statement",
      text: "Final statement",
      statementable: decision,
      created_by: @user,
      updated_by: @user,
      tenant: @tenant,
      collective: @collective,
      deadline: Time.current
    )

    summary = Note.create!(
      subtype: "summary",
      text: "Summary",
      summarizable: decision,
      created_by: @user,
      updated_by: @user,
      tenant: @tenant,
      collective: @collective,
      deadline: Time.current
    )

    assert_equal summary, decision.reload.summary
  end

  test "destroying summarizable destroys its summary" do
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)

    summary = Note.create!(
      subtype: "summary",
      text: "Summary",
      summarizable: decision,
      created_by: @user,
      updated_by: @user,
      tenant: @tenant,
      collective: @collective,
      deadline: Time.current
    )

    assert_difference -> { Note.where(id: summary.id).count }, -1 do
      decision.destroy!
    end
  end

  test "can_write_summary? returns false for nil user" do
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    assert_not decision.can_write_summary?(nil)
  end

  test "can_write_summary? returns false for a member without the summarizer role" do
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    assert_not decision.can_write_summary?(@user)
  end

  test "can_write_summary? returns true for a member with the summarizer role" do
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    @collective.collective_members.find_by(user: @user).add_role!('summarizer')
    assert decision.can_write_summary?(@user)
  end

  test "can_write_summary? returns true when the collective allows any member to summarize" do
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    @collective.settings['any_member_can_summarize'] = true
    @collective.save!
    assert decision.can_write_summary?(@user)
  end

  test "can_write_summary? returns false for a non-member" do
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    outsider = create_user
    assert_not decision.can_write_summary?(outsider)
  end

  test "can_write_summary? returns false for an archived summarizer" do
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    member = @collective.collective_members.find_by(user: @user)
    member.add_role!('summarizer')
    member.archive!
    assert_not decision.can_write_summary?(@user)
  end
end
