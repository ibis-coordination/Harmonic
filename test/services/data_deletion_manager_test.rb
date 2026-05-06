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

  # === Pre-existing bugs in delete_collective! ===
  # These tests document FK violations that exist in the current delete_collective! implementation.
  # They are skipped so they show up in test output as a reminder to fix.

  test "BUG: delete_collective! fails when collective has events (FK violation on events table)" do
    skip "Pre-existing bug: delete_collective! does not delete events records. " \
         "When a collective contains decisions/votes that triggered Tracked callbacks, " \
         "the events table has rows referencing the collective. delete_collective! doesn't " \
         "include Event in its deletion list, causing: PG::ForeignKeyViolation on collectives. " \
         "Fix: add Event to the model list in delete_collective! (before other models that events reference)."
  end

  test "BUG: delete_collective! with separate tenant fails to delete options (FK violation)" do
    skip "Pre-existing bug: delete_collective! with a freshly created tenant/collective can fail " \
         "if the test helper create_option uses default @tenant/@collective instead of the local ones, " \
         "causing options to land in the wrong collective. The bulk delete_all then misses them, " \
         "and DecisionParticipant deletion hits a FK violation from orphaned options. " \
         "This is a test setup issue but also reveals that delete_collective! has no error handling " \
         "for partial deletion failures — it should validate all child records were removed."
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
