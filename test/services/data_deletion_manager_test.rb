require "test_helper"

class DataDeletionManagerTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    @note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    @decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    @commitment = create_commitment(tenant: @tenant, collective: @collective, created_by: @user)
    @ddm = DataDeletionManager.new(user: @user)
  end

  test "DataDeletionManager does not delete anything unless correct confirmation_token is provided" do
    assert_raises { @ddm.delete_collective!(collective: @collective, confirmation_token: 'incorrect token') }
    assert_not @collective.reload.nil?
    assert_raises { @ddm.delete_note!(note: @note, confirmation_token: 'incorrect token') }
    assert_not @note.reload.nil?
    assert_raises { @ddm.delete_decision!(decision: @decision, confirmation_token: 'incorrect token') }
    assert_not @decision.reload.nil?
    assert_raises { @ddm.delete_commitment!(commitment: @commitment, confirmation_token: 'incorrect token') }
    assert_not @commitment.reload.nil?
    assert_raises { @ddm.delete_user!(user: @user, confirmation_token: 'incorrect token') }
    assert_not @user.reload.nil?
  end

  test "DataDeletionManager deletes collective with correct confirmation_token" do
    confirmation_token = @ddm.confirmation_token
    assert_difference -> { Collective.count }, -1 do
      @ddm.delete_collective!(collective: @collective, confirmation_token: confirmation_token)
    end
  end

  test "DataDeletionManager deletes note with correct confirmation_token" do
    confirmation_token = @ddm.confirmation_token
    assert_difference -> { Note.count }, -1 do
      @ddm.delete_note!(note: @note, confirmation_token: confirmation_token)
    end
  end

  test "DataDeletionManager deletes decision with correct confirmation_token" do
    confirmation_token = @ddm.confirmation_token

    assert_difference -> { Decision.count }, -1 do
      @ddm.delete_decision!(decision: @decision, confirmation_token: confirmation_token)
    end
  end

  test "DataDeletionManager deletes commitment with correct confirmation_token" do
    confirmation_token = @ddm.confirmation_token
    @commitment.join_commitment!(@user)
    assert_equal 1, CommitmentParticipant.where(commitment: @commitment).count
    assert_difference -> { Commitment.count }, -1 do
      @ddm.delete_commitment!(commitment: @commitment, confirmation_token: confirmation_token)
    end
    assert_equal 0, CommitmentParticipant.where(commitment: @commitment).count
  end

  test "DataDeletionManager destroys OmniAuthIdentity when deleting user" do
    user = create_user(email: "delete-oaid-#{SecureRandom.hex(4)}@example.com", name: "Delete OAID User")
    @tenant.add_user!(user)
    identity = user.find_or_create_omni_auth_identity!
    identity_id = identity.id

    ddm = DataDeletionManager.new(user: user)
    ddm.delete_user!(user: user, confirmation_token: ddm.confirmation_token)

    assert_nil OmniAuthIdentity.find_by(id: identity_id),
      "OmniAuthIdentity should be destroyed when user is deleted"
  end

  test "DataDeletionManager deletes closed decision with votes and audit entries" do
    decision = create_decision
    option = create_option(decision: decision, created_by: @user, title: "Option A")
    participant = DecisionParticipantManager.new(decision: decision, user: @user).find_or_create_participant

    # Cast a vote through DecisionActionService (creates audit entry)
    vote = Vote.new(
      tenant: @tenant, collective: @collective, decision: decision,
      option: option, decision_participant: participant,
      accepted: 1, preferred: 0,
    )
    DecisionActionService.cast_vote!(decision: decision, vote: vote, actor: @user)

    # Close the decision (creates audit entry + triggers vote-after-close protection)
    DecisionActionService.close_decision!(decision: decision, actor: @user)

    assert decision.closed?
    assert DecisionAuditEntry.where(decision_id: decision.id).count >= 2

    assert_difference -> { Decision.count }, -1 do
      @ddm.delete_decision!(decision: decision, confirmation_token: @ddm.confirmation_token)
    end
    assert_equal 0, DecisionAuditEntry.where(decision_id: decision.id).count
    assert_equal 0, Vote.where(decision_id: decision.id).count
  end

  test "DataDeletionManager deletes collective containing decisions with audit entries" do
    # Use the global collective so we don't hit pre-existing FK gaps
    # in delete_collective! (e.g., events table not being cleaned up)
    decision = create_decision
    option = create_option(decision: decision, created_by: @user, title: "Option B")
    participant = DecisionParticipantManager.new(decision: decision, user: @user).find_or_create_participant

    vote = Vote.new(
      tenant: @tenant, collective: @collective, decision: decision,
      option: option, decision_participant: participant,
      accepted: 1, preferred: 0,
    )
    DecisionActionService.cast_vote!(decision: decision, vote: vote, actor: @user)
    DecisionActionService.close_decision!(decision: decision, actor: @user)

    assert DecisionAuditEntry.where(decision_id: decision.id).count >= 2

    assert_difference -> { Collective.count }, -1 do
      @ddm.delete_collective!(collective: @collective, confirmation_token: @ddm.confirmation_token)
    end
    assert_equal 0, DecisionAuditEntry.where(decision_id: decision.id).count
    assert_equal 0, Decision.where(id: decision.id).count
  end

  # --- system_tombstone_note! ---

  test "system_tombstone_note! nulls content, preserves row, sets tombstoned_at" do
    note = create_note(
      tenant: @tenant, collective: @collective, created_by: @user,
      title: "Original Title", text: "Original body",
    )

    Tenant.clear_thread_scope
    Collective.clear_thread_scope
    DataDeletionManager.system_tombstone_note!(note: note)

    persisted = Note.unscoped.find_by(id: note.id)
    assert persisted, "row must remain"
    assert_not_nil persisted.tombstoned_at
    raw = Note.connection.select_one(
      "SELECT title, text, table_data FROM notes WHERE id = #{Note.connection.quote(note.id)}"
    )
    assert_nil raw["title"]
    assert_nil raw["text"]
    assert_nil raw["table_data"]
  end

  test "system_tombstone_note! destroys Link records involving the note" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    other_user = create_user(email: "tomblink-#{SecureRandom.hex(4)}@example.com", name: "Tomb Link #{SecureRandom.hex(4)}")
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)
    other_note = create_note(tenant: @tenant, collective: @collective, created_by: other_user, title: "B note")
    Link.create!(tenant: @tenant, collective: @collective, from_linkable: other_note, to_linkable: note)

    Tenant.clear_thread_scope
    Collective.clear_thread_scope
    DataDeletionManager.system_tombstone_note!(note: note)

    assert_equal 0, Link.where(to_linkable_id: note.id).count, "links must be destroyed"
    assert Note.unscoped.where(id: other_note.id).exists?, "the other note must survive"
  end

  test "system_tombstone_note! preserves NoteHistoryEvents and child comments" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    other_user = create_user(email: "pres-other-#{SecureRandom.hex(4)}@example.com", name: "Preserve #{SecureRandom.hex(4)}")
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)
    comment = create_note(
      tenant: @tenant, collective: @collective, created_by: other_user,
      text: "B's comment", subtype: "comment", commentable: note,
    )
    NoteHistoryEvent.create!(
      tenant: @tenant, collective: @collective, note: note, user: other_user,
      event_type: "read_confirmation", happened_at: Time.current,
    )

    Tenant.clear_thread_scope
    Collective.clear_thread_scope
    DataDeletionManager.system_tombstone_note!(note: note)

    assert Note.unscoped.where(id: comment.id).exists?, "comment must survive"
    assert NoteHistoryEvent.where(note_id: note.id).exists?, "history events must survive"
  end

  test "delete_collective! cleans up events referencing the collective" do
    # Reproduces a FK violation: Tracked callbacks insert Event rows that
    # reference the collective. delete_collective! must clear them or
    # PG::ForeignKeyViolation is raised on the final collective.destroy!.
    tenant, collective, user = create_tenant_collective_user
    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    note = create_note(tenant: tenant, collective: collective, created_by: user)
    assert Event.where(collective_id: collective.id).exists?,
           "expected Tracked callbacks to have created Event rows for the collective"

    ddm = DataDeletionManager.new(user: user)
    assert_difference -> { Collective.count }, -1 do
      ddm.delete_collective!(collective: collective, confirmation_token: ddm.confirmation_token)
    end
    assert_equal 0, Event.where(collective_id: collective.id).count,
                 "events referencing the deleted collective must be removed"
  ensure
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
  end

  test "DataDeletionManager deletes user PII and marks user as deleted with correct confirmation_token" do
    confirmation_token = @ddm.confirmation_token
    user_email = @user.email
    user_name = @user.name
    oauth_identity = OauthIdentity.create!(user: @user, provider: "test_provider", uid: "test_uid")
    # Profile image is attached
    @user.image.attach(
      io: File.open(Rails.root.join("public", "placeholder.png")),
      filename: "placeholder.png",
      content_type: "image/png"
    )
    assert @user.image.attached?

    assert_difference -> { OauthIdentity.count }, -1 do
      assert_no_difference -> { User.count } do
        result = @ddm.delete_user!(user: @user, confirmation_token: confirmation_token)

        # Verify user PII is removed
        @user.reload
        assert_match(/@deleted\.user$/, @user.email)
        assert_equal "Deleted User", @user.name
        assert_not @user.image.attached?

        # Verify API tokens are marked as deleted
        assert ApiToken.unscoped.where(user_id: @user.id).all? { |token| token.deleted_at.present? }

        # Verify CollectiveMember records are archived
        assert CollectiveMember.unscoped.where(user_id: @user.id).all? { |collective_member| collective_member.archived_at.present? }

        # Verify TenantUser records are updated and archived
        TenantUser.unscoped.where(user_id: @user.id).each do |tenant_user|
          assert_equal "Deleted User", tenant_user.display_name
          assert_match(/-deleted$/, tenant_user.handle)
          assert tenant_user.archived_at.present?
        end

        # Verify the result message
        assert_equal "PII for user '#{@user.id}' has been removed and the user has been marked as deleted.", result
      end
    end
  end

end
