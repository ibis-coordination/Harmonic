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
    # Stripe calls are webmock-stubbed, but the client refuses to build a
    # request without a key (CI has none configured).
    @original_stripe_key = Stripe.api_key
    Stripe.api_key = "sk_test_fake"
  end

  def teardown
    Stripe.api_key = @original_stripe_key
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
    rule = AutomationRule.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      name: "Collective rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: [{ "type" => "internal_action", "action" => "create_note", "params" => { "text" => "hi" } }],
      enabled: true,
    )

    @ddm.delete_user!(user: @user, confirmation_token: @ddm.confirmation_token)

    assert @collective.reload.archived_at.present?, "a collective left with no members must be archived"
    assert_not rule.reload.enabled, "the archived collective's automations must be disabled"
  end

  test "delete_user! blocks when the only other admin already left the collective" do
    T.must(@collective.collective_members.find_by(user_id: @user.id)).add_role!("admin")
    former_admin = create_user(email: "former-#{SecureRandom.hex(4)}@example.com", name: "Former Admin")
    @tenant.add_user!(former_admin)
    @collective.add_user!(former_admin)
    former_membership = T.must(@collective.collective_members.find_by(user_id: former_admin.id))
    former_membership.add_role!("admin")
    former_membership.update!(archived_at: Time.current)
    remaining = create_user(email: "remaining-#{SecureRandom.hex(4)}@example.com", name: "Remaining Member")
    @tenant.add_user!(remaining)
    @collective.add_user!(remaining)

    error = assert_raises(RuntimeError) do
      @ddm.delete_user!(user: @user, confirmation_token: @ddm.confirmation_token)
    end
    assert_match @collective.handle, error.message
  end

  test "delete_user! blocks for sole-admin collectives in other tenants" do
    tenant2, collective2, user2 = create_tenant_collective_user
    tenant2.add_user!(@user)
    collective2.add_user!(@user)
    CollectiveMember.tenant_scoped_only(tenant2.id)
      .find_by!(collective_id: collective2.id, user_id: @user.id).add_role!("admin")
    CollectiveMember.tenant_scoped_only(tenant2.id)
      .find_by!(collective_id: collective2.id, user_id: user2.id).remove_role!("admin")

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    error = assert_raises(RuntimeError) do
      @ddm.delete_user!(user: @user, confirmation_token: @ddm.confirmation_token)
    end
    assert_match collective2.handle, error.message
  ensure
    Tenant.clear_thread_scope
  end

  test "delete_user! archives solo collectives in other tenants but not shared ones" do
    tenant2, collective2, user2 = create_tenant_collective_user
    tenant2.add_user!(@user)
    # Shared collective in tenant2: user2 stays admin, @user is a plain member.
    collective2.add_user!(@user)
    # Solo collective in tenant2: @user is the only member and sole admin.
    solo = create_collective(tenant: tenant2, created_by: @user, name: "Solo T2", handle: "solo-t2-#{SecureRandom.hex(4)}")
    solo.add_user!(@user)
    CollectiveMember.tenant_scoped_only(tenant2.id)
      .find_by!(collective_id: solo.id, user_id: @user.id).add_role!("admin")

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    @ddm.delete_user!(user: @user, confirmation_token: @ddm.confirmation_token)
    Tenant.clear_thread_scope

    assert Collective.tenant_scoped_only(tenant2.id).find(solo.id).archived_at.present?,
           "the solo collective in the other tenant must be archived"
    assert_nil Collective.tenant_scoped_only(tenant2.id).find(collective2.id).archived_at,
               "the shared collective in the other tenant must not be archived"
    assert CollectiveMember.tenant_scoped_only(tenant2.id)
      .where(user_id: @user.id).all? { |cm| cm.archived_at.present? },
           "memberships in the other tenant must be archived"
  ensure
    Tenant.clear_thread_scope
  end

  test "delete_user! can be re-run after a partial vendor-side failure" do
    sc = StripeCustomer.create!(
      billable: @user, stripe_id: "cus_rerun_test", active: true,
      stripe_subscription_id: "sub_rerun_test",
    )
    stripe_missing = lambda do |kind, id|
      { status: 404, body: { error: { type: "invalid_request_error", code: "resource_missing",
                                      message: "No such #{kind}: '#{id}'" } }.to_json }
    end
    stub_request(:delete, %r{https://api\.stripe\.com/v1/subscriptions/sub_rerun_test})
      .to_return(stripe_missing.call("subscription", "sub_rerun_test"))
    stub_request(:delete, %r{https://api\.stripe\.com/v1/customers/cus_rerun_test})
      .to_return(stripe_missing.call("customer", "cus_rerun_test"))

    @ddm.delete_user!(user: @user, confirmation_token: @ddm.confirmation_token)
    assert_not sc.reload.active

    # Second run must be a no-op, not a crash.
    ddm2 = DataDeletionManager.new(user: @user)
    ddm2.delete_user!(user: @user, confirmation_token: ddm2.confirmation_token)
    assert_match(/@deleted\.user$/, @user.reload.email)
  end

  test "delete_user! cancels the subscription and deletes the Stripe customer" do
    sc = StripeCustomer.create!(
      billable: @user, stripe_id: "cus_scrub_test", active: true,
      stripe_subscription_id: "sub_scrub_test",
    )
    cancel_stub = stub_request(:delete, %r{https://api\.stripe\.com/v1/subscriptions/sub_scrub_test})
      .to_return(status: 200, body: { id: "sub_scrub_test", status: "canceled" }.to_json)
    delete_stub = stub_request(:delete, %r{https://api\.stripe\.com/v1/customers/cus_scrub_test})
      .to_return(status: 200, body: { id: "cus_scrub_test", deleted: true }.to_json)

    @ddm.delete_user!(user: @user, confirmation_token: @ddm.confirmation_token)

    assert_requested cancel_stub
    assert_requested delete_stub
    assert_not sc.reload.active, "the local StripeCustomer row must be marked inactive"
    assert StripeCustomer.exists?(sc.id), "the local row must survive for ledger references"
  end

  test "delete_user! aborts before scrubbing anything when Stripe cleanup fails" do
    StripeCustomer.create!(
      billable: @user, stripe_id: "cus_fail_test", active: true,
      stripe_subscription_id: "sub_fail_test",
    )
    stub_request(:delete, %r{https://api\.stripe\.com/v1/subscriptions/sub_fail_test})
      .to_return(status: 500, body: { error: { message: "boom" } }.to_json)

    assert_raises(Stripe::StripeError) do
      @ddm.delete_user!(user: @user, confirmation_token: @ddm.confirmation_token)
    end
    assert_no_match(/@deleted\.user/, @user.reload.email)
    assert_nil @user.sessions_revoked_at, "nothing may be scrubbed when billing cleanup fails"
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

  test "delete_user! stamps scrubbed_at on every tenant user" do
    tenant_b = create_tenant
    tenant_b.add_user!(@user)

    @ddm.delete_user!(user: @user, confirmation_token: @ddm.confirmation_token)

    tenant_users = TenantUser.for_user_across_tenants(@user).to_a
    assert_equal 2, tenant_users.size
    assert tenant_users.all? { |tu| tu.scrubbed_at.present? },
           "every tenant slice must be marked scrubbed"
  end

  # === delete_tenant_user! (per-subdomain slice) ===

  def setup_second_tenant_with_membership!
    tenant_b = create_tenant
    tenant_b.add_user!(@user)
    collective_b = create_collective(tenant: tenant_b, created_by: @user)
    collective_b.add_user!(@user)
    [tenant_b, collective_b]
  end

  test "delete_tenant_user! scrubs only that tenant's slice and leaves the account usable elsewhere" do
    tenant_b, collective_b = setup_second_tenant_with_membership!
    identity = @user.find_or_create_omni_auth_identity!
    original_email = @user.email

    tu_a = TenantUser.tenant_scoped_only(@tenant.id).find_by(user_id: @user.id)
    tu_a.update!(bio: "A bio", location: "Seattle", website: "https://example.com")
    tu_b = TenantUser.tenant_scoped_only(tenant_b.id).find_by(user_id: @user.id)
    original_handle_b = tu_b.handle

    rule_a = AutomationRule.create!(
      tenant: @tenant, user: @user, created_by: @user,
      name: "Webhook A", trigger_type: "event",
      trigger_config: { "event_types" => ["notifications.delivered"] },
      actions: { "webhook_url" => "https://example.com/hook" }, enabled: true,
    )
    export_a = DataExport.create!(
      tenant: @tenant, collective: @collective, user: @user,
      status: "completed", export_type: "user", expires_at: 7.days.from_now,
    )
    other = create_user(email: "slice-#{SecureRandom.hex(4)}@example.com", name: "Slice Other")
    @tenant.add_user!(other)
    grant_a = TrusteeGrant.create!(tenant: @tenant, granting_user: @user, trustee_user: other)

    option = create_option(decision: @decision, created_by: @user, title: "Slice Option")
    entry = DecisionAuditService.record_option!(
      decision: @decision, option: option, actor: @user, action: "option_added",
    )

    @ddm.delete_tenant_user!(user: @user, tenant: @tenant, confirmation_token: @ddm.confirmation_token)

    tu_a.reload
    assert_equal "Deleted User", tu_a.display_name
    assert_match(/-deleted\z/, tu_a.handle)
    assert_nil tu_a.bio
    assert tu_a.archived_at.present?
    assert tu_a.scrubbed_at.present?

    tu_b.reload
    assert_equal original_handle_b, tu_b.handle, "the other subdomain's profile must be untouched"
    assert_nil tu_b.scrubbed_at

    assert_equal original_email, @user.reload.email, "login identity survives a per-subdomain scrub"
    assert_nil @user.scrubbed_at
    assert_nil @user.sessions_revoked_at, "the shared session survives"
    assert OmniAuthIdentity.exists?(identity.id)

    assert rule_a.reload.deleted_at.present?, "rules in the scrubbed tenant are soft-deleted"
    assert_not DataExport.unscoped.exists?(export_a.id), "exports in the scrubbed tenant are destroyed"
    assert grant_a.reload.revoked_at.present?, "trustee authorizations in the scrubbed tenant are revoked"

    entry.reload
    assert_nil entry.actor_id, "audit entries in the scrubbed tenant lose the actor identity"

    membership_a = CollectiveMember.tenant_scoped_only(@tenant.id)
      .find_by(collective_id: @collective.id, user_id: @user.id)
    assert membership_a.archived_at.present?, "memberships in the scrubbed tenant are archived"
    membership_b = CollectiveMember.tenant_scoped_only(tenant_b.id)
      .find_by(collective_id: collective_b.id, user_id: @user.id)
    assert_nil membership_b.archived_at, "memberships elsewhere survive"
  end

  test "delete_tenant_user! leaves audit entries in other tenants attributed" do
    tenant_b, collective_b = setup_second_tenant_with_membership!
    decision_b = create_decision(tenant: tenant_b, collective: collective_b, created_by: @user)
    option_b = create_option(tenant: tenant_b, collective: collective_b, decision: decision_b, created_by: @user, title: "B Option")
    entry_b = DecisionAuditService.record_option!(
      decision: decision_b, option: option_b, actor: @user, action: "option_added",
    )

    @ddm.delete_tenant_user!(user: @user, tenant: @tenant, confirmation_token: @ddm.confirmation_token)

    assert_equal @user.id, entry_b.reload.actor_id,
                 "audit entries in other tenants keep their attribution"
  end

  test "delete_tenant_user! archives the user's agents in that tenant only" do
    agent = create_ai_agent(parent: @user)
    @tenant.add_user!(agent)
    tenant_b, _collective_b = setup_second_tenant_with_membership!
    tenant_b.add_user!(agent)

    @ddm.delete_tenant_user!(user: @user, tenant: @tenant, confirmation_token: @ddm.confirmation_token)

    agent_tu_a = TenantUser.tenant_scoped_only(@tenant.id).find_by(user_id: agent.id)
    agent_tu_b = TenantUser.tenant_scoped_only(tenant_b.id).find_by(user_id: agent.id)
    assert agent_tu_a.archived_at.present?, "the agent's presence in the scrubbed tenant is archived"
    assert_nil agent_tu_b.archived_at, "the agent's presence elsewhere survives"
  end

  test "delete_tenant_user! is blocked by sole-admin collectives in that tenant only" do
    tenant_b, collective_b = setup_second_tenant_with_membership!
    T.must(collective_b.collective_members.find_by(user_id: @user.id)).add_role!("admin")
    other = create_user(email: "slice-blk-#{SecureRandom.hex(4)}@example.com", name: "Slice Blk")
    tenant_b.add_user!(other)
    collective_b.add_user!(other)

    # Sole admin of a shared collective in B does not block scrubbing A...
    @ddm.delete_tenant_user!(user: @user, tenant: @tenant, confirmation_token: @ddm.confirmation_token)

    # ...but blocks scrubbing B.
    error = assert_raises(RuntimeError) do
      @ddm.delete_tenant_user!(user: @user, tenant: tenant_b, confirmation_token: @ddm.confirmation_token)
    end
    assert_match collective_b.handle, error.message
  end

  test "delete_tenant_user! archives collectives where the user was the only member, within that tenant" do
    setup_second_tenant_with_membership!
    solo = create_collective(tenant: @tenant, created_by: @user, name: "Solo A", handle: "solo-a-#{SecureRandom.hex(3)}")
    solo.add_user!(@user)
    T.must(solo.collective_members.find_by(user_id: @user.id)).add_role!("admin")

    @ddm.delete_tenant_user!(user: @user, tenant: @tenant, confirmation_token: @ddm.confirmation_token)

    assert solo.reload.archived_at.present?, "solo collectives in the scrubbed tenant are archived"
  end
end
