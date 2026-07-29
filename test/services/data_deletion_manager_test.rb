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

  test "delete_user! revokes sessions, refresh tokens, and push subscriptions" do
    RefreshToken.issue!(user: @user)
    subscription = WebPushSubscription.upsert_for!(
      user: @user,
      endpoint: "https://push.example.com/send/ddm-#{SecureRandom.hex(4)}",
      p256dh_key: "p256dh-key",
      auth_key: "auth-key",
    )

    @ddm.delete_user!(user: @user, confirmation_token: @ddm.confirmation_token)

    assert @user.reload.sessions_revoked_at.present?, "sessions_revoked_at must be set"
    assert RefreshToken.where(user_id: @user.id).all? { |t| t.revoked_at.present? },
           "refresh tokens must be revoked"
    assert subscription.reload.revoked_at.present?, "push subscriptions must be revoked"
  end

  test "delete_user! revokes trustee authorizations in both directions" do
    other = create_user(email: "trustee-#{SecureRandom.hex(4)}@example.com", name: "Trustee Other")
    @tenant.add_user!(other)
    granted = TrusteeGrant.create!(tenant: @tenant, granting_user: @user, trustee_user: other)
    received = TrusteeGrant.create!(tenant: @tenant, granting_user: other, trustee_user: @user)

    @ddm.delete_user!(user: @user, confirmation_token: @ddm.confirmation_token)

    assert granted.reload.revoked_at.present?, "authorization granted by the user must be revoked"
    assert received.reload.revoked_at.present?, "authorization held by the user must be revoked"
  end

  test "delete_user! soft-deletes user-owned automation rules" do
    rule = AutomationRule.create!(
      tenant: @tenant,
      user: @user,
      created_by: @user,
      name: "User notification webhook",
      trigger_type: "event",
      trigger_config: { "event_types" => ["notifications.delivered"] },
      actions: { "webhook_url" => "https://example.com/hook" },
      enabled: true,
    )

    @ddm.delete_user!(user: @user, confirmation_token: @ddm.confirmation_token)

    assert rule.reload.deleted_at.present?, "user-owned rules must be soft-deleted"
  end

  test "delete_user! clears free-text profile fields on tenant users" do
    tenant_user = TenantUser.for_user_across_tenants(@user).first
    tenant_user.update!(bio: "A bio", location: "Seattle", website: "https://example.com")

    @ddm.delete_user!(user: @user, confirmation_token: @ddm.confirmation_token)

    tenant_user.reload
    assert_nil tenant_user.bio, "bio must be cleared"
    assert_nil tenant_user.location, "location must be cleared"
    assert_nil tenant_user.website, "website must be cleared"
  end

  test "delete_user! destroys the user's data exports" do
    export = DataExport.create!(
      tenant: @tenant,
      collective: @collective,
      user: @user,
      status: "completed",
      export_type: "user",
      expires_at: 7.days.from_now,
    )

    @ddm.delete_user!(user: @user, confirmation_token: @ddm.confirmation_token)

    assert_not DataExport.unscoped.exists?(export.id), "the user's exports must be destroyed"
  end

  test "delete_user! scrubs the user's identity from decision audit entries" do
    option = create_option(decision: @decision, created_by: @user, title: "Scrub Option")
    entry = DecisionAuditService.record_option!(
      decision: @decision, option: option, actor: @user, action: "option_added",
    )

    @ddm.delete_user!(user: @user, confirmation_token: @ddm.confirmation_token)

    entry.reload
    assert_nil entry.actor_id, "actor_id must be scrubbed"
    assert_nil entry.actor_handle, "actor_handle must be scrubbed"
    assert_nil entry.actor_token_salt, "actor_token_salt must be scrubbed"

    result = DecisionAuditVerifier.verify_chain(@decision)
    assert result[:valid], "the chain must stay verifiable after the scrub"
    assert_equal :unattributable, result[:binding_statuses][entry.sequence_number],
                 "the scrubbed entry must verify as unattributable, not tampered"
  end

  test "delete_user! scrubs the user's identity as representative from audit entries" do
    other = create_user(email: "rep-actor-#{SecureRandom.hex(4)}@example.com", name: "Rep Actor")
    @tenant.add_user!(other)
    @collective.add_user!(other)
    T.must(@collective.collective_members.find_by(user_id: other.id)).add_role!("admin")
    grant = create_trustee_authorization(
      tenant: @tenant, granting_user: other, trustee_user: @user,
      permissions: { "vote" => true }, accepted: true,
    )
    session = create_trustee_authorization_representation_session(tenant: @tenant, trustee_grant: grant)
    option = create_option(decision: @decision, created_by: other, title: "Rep Option")
    entry = DecisionAuditService.record_option!(
      decision: @decision, option: option, actor: other, action: "option_added",
      representation_session: session,
    )
    assert_equal @user.id, entry.representative_id

    @ddm.delete_user!(user: @user, confirmation_token: @ddm.confirmation_token)

    entry.reload
    assert_nil entry.representative_id, "representative_id must be scrubbed"
    assert_nil entry.representative_handle, "representative_handle must be scrubbed"
    assert_nil entry.representative_token_salt, "representative_token_salt must be scrubbed"
    assert_equal other.id, entry.actor_id, "the other user's actor identity must survive"
  end

  test "delete_user! is blocked while the user is the sole admin of a collective with other members" do
    T.must(@collective.collective_members.find_by(user_id: @user.id)).add_role!("admin")
    other = create_user(email: "member-#{SecureRandom.hex(4)}@example.com", name: "Other Member")
    @tenant.add_user!(other)
    @collective.add_user!(other)

    error = assert_raises(RuntimeError) do
      @ddm.delete_user!(user: @user, confirmation_token: @ddm.confirmation_token)
    end
    assert_match @collective.handle, error.message
    assert_match(/admin/i, error.message)
    assert_no_match(/@deleted\.user/, @user.reload.email)
  end

  test "delete_user! proceeds after the admin role is transferred" do
    T.must(@collective.collective_members.find_by(user_id: @user.id)).add_role!("admin")
    other = create_user(email: "successor-#{SecureRandom.hex(4)}@example.com", name: "Successor")
    @tenant.add_user!(other)
    @collective.add_user!(other)
    T.must(@collective.collective_members.find_by(user_id: other.id)).add_role!("admin")

    @ddm.delete_user!(user: @user, confirmation_token: @ddm.confirmation_token)

    assert_match(/@deleted\.user$/, @user.reload.email)
    assert_nil @collective.reload.archived_at, "a collective with a remaining admin must not be archived"
  end

  test "delete_user! archives collectives where the user was the only member" do
    T.must(@collective.collective_members.find_by(user_id: @user.id)).add_role!("admin")

    @ddm.delete_user!(user: @user, confirmation_token: @ddm.confirmation_token)

    assert @collective.reload.archived_at.present?, "a collective left with no members must be archived"
  end

  test "delete_user! archives child AI agents and stops their automations" do
    agent = create_ai_agent(parent: @user)
    @tenant.add_user!(agent) unless TenantUser.for_user_across_tenants(agent).exists?
    agent_rule = AutomationRule.create!(
      tenant: @tenant,
      ai_agent: agent,
      created_by: @user,
      name: "Agent task rule",
      trigger_type: "event",
      trigger_config: { "event_types" => ["notifications.delivered"] },
      actions: { "task" => "Summarize the day" },
      enabled: true,
    )

    @ddm.delete_user!(user: @user, confirmation_token: @ddm.confirmation_token)

    assert TenantUser.for_user_across_tenants(agent).all? { |tu| tu.archived_at.present? },
           "the agent's tenant users must be archived"
    assert agent_rule.reload.deleted_at.present?, "agent-owned rules must be soft-deleted"
    assert TrusteeGrant.for_user_across_tenants(agent).all? { |g| g.revoked_at.present? || g.declined_at.present? },
           "the agent's trustee authorizations must be revoked"
  end
end
