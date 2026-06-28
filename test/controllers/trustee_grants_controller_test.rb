require "test_helper"

class TrusteeGrantsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @collective = @global_collective
    @collective.enable_api!
    @user = @global_user

    # Create another user to delegate to/from
    @other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(@other_user)
    @collective.add_user!(@other_user)

    @api_token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.valid_scopes,
    )
    @plaintext_token = @api_token.plaintext_token
    @headers = {
      "Authorization" => "Bearer #{@plaintext_token}",
      "Accept" => "text/markdown",
      "Content-Type" => "application/json",
    }
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  def is_markdown?
    response.content_type.starts_with?("text/markdown")
  end

  # === Index Tests ===

  test "user can view their own trustee grants" do
    get "/u/#{@user.handle}/settings/trustee-authorizations", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_includes response.body, "Trustee Authorizations for"
  end

  test "granted trustee grants are listed in index" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @user,
      trustee_user: @other_user,
      permissions: { "create_note" => true },
    )

    get "/u/#{@user.handle}/settings/trustee-authorizations", headers: @headers
    assert_response :success
    # Check for display name or handle since the other_user's handle varies
    assert_includes response.body, @other_user.display_name || @other_user.name
  end

  test "received trustee grants are listed in index" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @other_user,
      trustee_user: @user,
      permissions: { "create_note" => true },
    )
    permission.accept!

    get "/u/#{@user.handle}/settings/trustee-authorizations", headers: @headers
    assert_response :success
    # Check for display name or handle since the other_user's handle varies
    assert_includes response.body, @other_user.display_name || @other_user.name
  end

  test "old /trustee-grants URLs 308-redirect to /trustee-authorizations" do
    # The UI vocabulary moved from "trustee grant" to "trustee authorization,"
    # and the URL slug moved with it. Old paths must continue to resolve so
    # bookmarks, saved agent code, and the inbound link surface keep working.
    # 308 (Permanent Redirect, method-preserving) ensures POSTs from external
    # callers that hardcoded the old path still land at the same controller.
    get "/u/#{@user.handle}/settings/trustee-grants", headers: @headers
    assert_response :permanent_redirect
    assert_equal "/u/#{@user.handle}/settings/trustee-authorizations", URI.parse(response.headers["Location"]).path

    grant = TrusteeGrant.create!(
      tenant: @tenant, granting_user: @user, trustee_user: @other_user,
      permissions: { "create_note" => true },
    )
    get "/u/#{@user.handle}/settings/trustee-grants/#{grant.truncated_id}", headers: @headers
    assert_response :permanent_redirect
    assert_equal "/u/#{@user.handle}/settings/trustee-authorizations/#{grant.truncated_id}",
                 URI.parse(response.headers["Location"]).path
  end

  test "old action-name URLs 308-redirect to the renamed actions" do
    # accept_trustee_grant / decline_trustee_grant / revoke_trustee_grant /
    # create_trustee_grant were renamed in the terminology sweep. Agents and
    # external callers that have the old action names hardcoded should land
    # at the new ones via method-preserving redirect.
    grant = TrusteeGrant.create!(
      tenant: @tenant, granting_user: @user, trustee_user: @other_user,
      permissions: { "create_note" => true },
    )

    {
      "accept_trustee_grant" => "accept_trustee_authorization",
      "decline_trustee_grant" => "decline_trustee_authorization",
      "revoke_trustee_grant" => "revoke_trustee_authorization",
    }.each do |old_action, new_action|
      get "/u/#{@user.handle}/settings/trustee-authorizations/#{grant.truncated_id}/actions/#{old_action}",
          headers: @headers
      assert_response :permanent_redirect, "GET #{old_action} should 308"
      assert_equal "/u/#{@user.handle}/settings/trustee-authorizations/#{grant.truncated_id}/actions/#{new_action}",
                   URI.parse(response.headers["Location"]).path

      post "/u/#{@user.handle}/settings/trustee-authorizations/#{grant.truncated_id}/actions/#{old_action}",
           headers: @headers
      assert_response :permanent_redirect, "POST #{old_action} should 308 (method-preserving)"
    end

    # create_trustee_grant lives at /new/actions/create_trustee_grant.
    get "/u/#{@user.handle}/settings/trustee-authorizations/new/actions/create_trustee_grant",
        headers: @headers
    assert_response :permanent_redirect
    assert_equal "/u/#{@user.handle}/settings/trustee-authorizations/new/actions/create_trustee_authorization",
                 URI.parse(response.headers["Location"]).path
  end

  # === Capability-dependency warning ===

  # When the trustee is an AI agent that lacks the rep-lifecycle capabilities
  # in its overall agent configuration, the grant show page should warn the
  # viewer — otherwise the agent silently fails on "your capabilities do not
  # include 'accept_trustee_authorization'" when it tries to engage with the
  # grant. The two grantable surfaces are independent (per-grant
  # TrusteeGrant::GRANTABLE_ACTIONS vs. the agent's overall
  # CapabilityCheck::AI_AGENT_GRANTABLE_ACTIONS), and the principal has no
  # visibility into the agent's capability set from the grant flow.

  test "show page warns when the trustee is an agent missing rep-lifecycle capabilities" do
    agent = create_ai_agent(parent: @user, name: "Capability-poor agent",
                            agent_configuration: { "mode" => "internal", "capabilities" => ["create_note"] })
    grant = TrusteeGrant.create!(
      tenant: @tenant, granting_user: @user, trustee_user: agent,
      permissions: { "create_note" => true },
    )

    body = get_show_as(@user.handle, grant)
    assert_match(/missing.*capabilit|capabilit.*missing|not enabled/i, body,
                 "Show page should warn the principal about the missing capabilities")
    assert_includes body, "accept_trustee_authorization",
                    "Warning should name the missing accept capability"
    assert_includes body, "start_representation",
                    "Warning should name the missing start capability"
    assert_includes body, "end_representation",
                    "Warning should name the missing end capability"
    assert_includes body, "/ai-agents/#{agent.handle}/settings",
                    "Warning should link to the agent's settings page where the parent can enable them"
  end

  test "show page does not warn when the agent has all rep-lifecycle capabilities" do
    agent = create_ai_agent(parent: @user, name: "Capability-complete agent",
                            agent_configuration: {
                              "mode" => "internal",
                              "capabilities" => [
                                "create_note",
                                "accept_trustee_authorization",
                                "start_representation",
                                "end_representation",
                              ],
                            })
    grant = TrusteeGrant.create!(
      tenant: @tenant, granting_user: @user, trustee_user: agent,
      permissions: { "create_note" => true },
    )

    body = get_show_as(@user.handle, grant)
    refute_match(/missing.*capabilit|capabilit.*missing/i, body,
                 "No warning when all required rep-lifecycle capabilities are enabled")
  end

  test "show page does not warn when the agent has no capability restrictions" do
    # capabilities: nil means "all grantable actions allowed" — the
    # rep-lifecycle ones are implicitly granted.
    agent = create_ai_agent(parent: @user, name: "Unrestricted agent",
                            agent_configuration: { "mode" => "internal" })
    grant = TrusteeGrant.create!(
      tenant: @tenant, granting_user: @user, trustee_user: agent,
      permissions: { "create_note" => true },
    )

    body = get_show_as(@user.handle, grant)
    refute_match(/missing.*capabilit|capabilit.*missing/i, body,
                 "No warning when the agent has no capability restrictions")
  end

  test "show page does not warn when the trustee is a human" do
    # The agent capability surface only applies to AI agents. Don't warn
    # when the trustee is a human even if the grant was just created.
    grant = TrusteeGrant.create!(
      tenant: @tenant, granting_user: @user, trustee_user: @other_user,
      permissions: { "create_note" => true },
    )

    body = get_show_as(@user.handle, grant)
    refute_match(/missing.*capabilit|capabilit.*missing/i, body,
                 "No warning when the trustee is a human user")
  end

  # === Grant-show action listing (state-aware) ===

  # The actions listed in the markdown frontmatter for /u/:handle/settings/
  # trustee-authorizations/:grant_id must reflect what's actually applicable
  # given the grant's state and the viewer's role. Today the show-page
  # frontmatter advertises all five rep-lifecycle actions unconditionally;
  # only the actions_index_show endpoint applies the state-aware filter.
  def get_show_as(viewer_handle, grant)
    get "/u/#{viewer_handle}/settings/trustee-authorizations/#{grant.truncated_id}", headers: @headers
    assert_response :success
    response.body
  end

  test "show frontmatter on a pending grant offers accept and decline to the trustee, nothing else" do
    grant = TrusteeGrant.create!(
      tenant: @tenant, granting_user: @other_user, trustee_user: @user,
      permissions: { "create_note" => true },
    )

    body = get_show_as(@user.handle, grant)
    assert_match(/name: accept_trustee_authorization\b/, body)
    assert_match(/name: decline_trustee_authorization\b/, body)
    refute_match(/name: revoke_trustee_authorization\b/, body,
                 "Trustee cannot revoke — only granting user can")
    refute_match(/name: start_representation\b/, body,
                 "Start_representation should not be offered on a pending grant")
    refute_match(/name: end_representation\b/, body)
  end

  test "show frontmatter on an active grant offers start_representation to the trustee" do
    grant = TrusteeGrant.create!(
      tenant: @tenant, granting_user: @other_user, trustee_user: @user,
      permissions: { "create_note" => true },
    )
    grant.accept!

    body = get_show_as(@user.handle, grant)
    assert_match(/name: start_representation\b/, body)
    refute_match(/name: end_representation\b/, body,
                 "No active session yet — end_representation shouldn't appear")
    refute_match(/name: accept_trustee_authorization\b/, body)
    refute_match(/name: decline_trustee_authorization\b/, body)
    refute_match(/name: revoke_trustee_authorization\b/, body,
                 "Trustee cannot revoke")
  end

  test "show frontmatter offers end_representation when an active session exists for this grant" do
    grant = TrusteeGrant.create!(
      tenant: @tenant, granting_user: @other_user, trustee_user: @user,
      permissions: { "create_note" => true },
    )
    grant.accept!
    RepresentationSession.tenant_scoped_only(@tenant.id).create!(
      tenant: @tenant,
      representative_user: @user,
      trustee_grant: grant,
      confirmed_understanding: true,
      began_at: Time.current,
    )

    body = get_show_as(@user.handle, grant)
    assert_match(/name: end_representation\b/, body)
    refute_match(/name: start_representation\b/, body,
                 "Cannot start a second session while one is active")
  end

  test "show frontmatter offers revoke to the granting user only" do
    grant = TrusteeGrant.create!(
      tenant: @tenant, granting_user: @user, trustee_user: @other_user,
      permissions: { "create_note" => true },
    )
    grant.accept!

    body = get_show_as(@user.handle, grant)
    assert_match(/name: revoke_trustee_authorization\b/, body,
                 "Granting user can revoke an active grant")
    refute_match(/name: start_representation\b/, body,
                 "Start_representation belongs to the trustee, not the grantor")
    refute_match(/name: accept_trustee_authorization\b/, body)
    refute_match(/name: decline_trustee_authorization\b/, body)
  end

  test "show frontmatter on a revoked grant offers no lifecycle actions" do
    grant = TrusteeGrant.create!(
      tenant: @tenant, granting_user: @user, trustee_user: @other_user,
      permissions: { "create_note" => true },
    )
    grant.accept!
    grant.revoke!

    body = get_show_as(@user.handle, grant)
    refute_match(/name: accept_trustee_authorization\b/, body)
    refute_match(/name: decline_trustee_authorization\b/, body)
    refute_match(/name: revoke_trustee_authorization\b/, body,
                 "Already revoked — revoke is a no-op")
    refute_match(/name: start_representation\b/, body)
    refute_match(/name: end_representation\b/, body)
  end

  test "pending grants offered to the trustee are described as offers, not requests" do
    # The "Pending Requests" header + "These users are requesting authority to
    # act on your behalf" copy inverts the relationship: the listed users are
    # the granting party, OFFERING the trustee authority to act on their
    # behalf. Pin the corrected wording so the inversion can't return.
    TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @other_user,
      trustee_user: @user,
      permissions: { "create_note" => true },
    )

    get "/u/#{@user.handle}/settings/trustee-authorizations", headers: @headers
    assert_response :success
    assert_not_includes response.body, "requesting authority to act on your behalf"
    assert_match(/granting you authority to act on their behalf/i, response.body)
  end

  # === New Page Tests ===

  test "user can view new trustee grant page" do
    get "/u/#{@user.handle}/settings/trustee-authorizations/new", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_includes response.body, "Create New Trustee Authorization"
  end

  test "new page lists available users" do
    get "/u/#{@user.handle}/settings/trustee-authorizations/new", headers: @headers
    assert_response :success
    assert_includes response.body, @other_user.handle
  end

  test "new page lists available capabilities" do
    get "/u/#{@user.handle}/settings/trustee-authorizations/new", headers: @headers
    assert_response :success
    assert_includes response.body, "create_note"
    assert_includes response.body, "vote"
    # #260: the form now renders the full grouped capability list, so actions
    # missing from the old hand-maintained subset must show up too.
    assert_includes response.body, "add_summary"
    assert_includes response.body, "report_content"
  end

  # === Create Tests ===

  test "user can create a trustee grant" do
    assert_difference "TrusteeGrant.unscoped.count" do
      post "/u/#{@user.handle}/settings/trustee-authorizations/new/actions/create_trustee_authorization",
        params: {
          trustee_user_id: @other_user.id,
          permissions: ["create_note", "vote"],
          collective_scope_mode: "all",
        }.to_json,
        headers: @headers
    end

    assert_response :success
    assert is_markdown?
    assert_includes response.body, "Trustee authorization request sent"

    permission = TrusteeGrant.unscoped.order(created_at: :desc).first
    assert_equal @user, permission.granting_user
    assert_equal @other_user, permission.trustee_user
    assert permission.pending?
    assert permission.has_action_permission?("create_note")
    assert permission.has_action_permission?("vote")
  end

  test "create_trustee_authorization requires trustee_user_id" do
    post "/u/#{@user.handle}/settings/trustee-authorizations/new/actions/create_trustee_authorization",
      params: { permissions: ["create_note"] }.to_json,
      headers: @headers

    assert_response :not_found
    assert_includes response.body, "Trustee user not found"
  end

  test "create_trustee_authorization can set expiration" do
    expires = 1.week.from_now.iso8601
    post "/u/#{@user.handle}/settings/trustee-authorizations/new/actions/create_trustee_authorization",
      params: {
        trustee_user_id: @other_user.id,
        permissions: ["create_note"],
        expires_at: expires,
      }.to_json,
      headers: @headers

    assert_response :success
    permission = TrusteeGrant.unscoped.order(created_at: :desc).first
    assert permission.expires_at.present?
  end

  test "create_trustee_authorization can set collective scope" do
    post "/u/#{@user.handle}/settings/trustee-authorizations/new/actions/create_trustee_authorization",
      params: {
        trustee_user_id: @other_user.id,
        permissions: ["create_note"],
        collective_scope_mode: "include",
        collective_ids: [@collective.id],
      }.to_json,
      headers: @headers

    assert_response :success
    permission = TrusteeGrant.unscoped.order(created_at: :desc).first
    assert_equal "include", permission.collective_scope["mode"]
    assert_includes permission.collective_scope["collective_ids"], @collective.id
  end

  # === Show Tests ===

  test "user can view a trustee grant they granted" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @user,
      trustee_user: @other_user,
      permissions: { "create_note" => true },
    )

    get "/u/#{@user.handle}/settings/trustee-authorizations/#{permission.truncated_id}", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_includes response.body, "Trustee Authorization:"
  end

  test "user can view a trustee grant they received" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @other_user,
      trustee_user: @user,
      permissions: { "create_note" => true },
    )

    get "/u/#{@user.handle}/settings/trustee-authorizations/#{permission.truncated_id}", headers: @headers
    assert_response :success
    assert is_markdown?
  end

  test "show page displays session history when sessions exist" do
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @other_user,
      trustee_user: @user,
      permissions: { "create_note" => true },
    )
    grant.accept!

    # Create a user representation session linked to this grant (no collective_id)
    session = RepresentationSession.create!(
      tenant: @tenant,
      collective: nil,  # User representation has no collective
      representative_user: @user,
      trustee_grant: grant,
      confirmed_understanding: true,
      began_at: 1.hour.ago,
      ended_at: 30.minutes.ago,
    )

    get "/u/#{@user.handle}/settings/trustee-authorizations/#{grant.truncated_id}", headers: @headers
    assert_response :success
    assert_includes response.body, "Session History"
    assert_includes response.body, session.truncated_id
  end

  test "show page displays empty state when no sessions exist" do
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @user,
      trustee_user: @other_user,
      permissions: { "create_note" => true },
    )

    get "/u/#{@user.handle}/settings/trustee-authorizations/#{grant.truncated_id}", headers: @headers
    assert_response :success
    assert_includes response.body, "Session History"
    assert_includes response.body, "No representation sessions"
  end

  # === Accept Tests ===

  test "trustee_user can accept a pending trustee grant" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @other_user,
      trustee_user: @user,
      permissions: { "create_note" => true },
    )

    assert permission.pending?

    post "/u/#{@user.handle}/settings/trustee-authorizations/#{permission.truncated_id}/actions/accept_trustee_authorization",
      headers: @headers

    assert_response :success
    assert_includes response.body, "Trustee authorization accepted"

    permission.reload
    assert permission.active?
  end

  test "granting_user cannot accept a trustee grant they granted" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @user,
      trustee_user: @other_user,
      permissions: { "create_note" => true },
    )

    post "/u/#{@user.handle}/settings/trustee-authorizations/#{permission.truncated_id}/actions/accept_trustee_authorization",
      headers: @headers

    assert_response :forbidden
    assert_includes response.body, "You can only accept trustee authorizations granted to you"

    permission.reload
    assert permission.pending?
  end

  test "cannot accept non-pending trustee grant" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @other_user,
      trustee_user: @user,
      permissions: { "create_note" => true },
    )
    permission.accept!

    post "/u/#{@user.handle}/settings/trustee-authorizations/#{permission.truncated_id}/actions/accept_trustee_authorization",
      headers: @headers

    assert_response :conflict
    assert_includes response.body, "not pending"
  end

  # === Decline Tests ===

  test "trustee_user can decline a pending trustee grant" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @other_user,
      trustee_user: @user,
      permissions: { "create_note" => true },
    )

    post "/u/#{@user.handle}/settings/trustee-authorizations/#{permission.truncated_id}/actions/decline_trustee_authorization",
      headers: @headers

    assert_response :success
    assert_includes response.body, "Trustee authorization declined"

    permission.reload
    assert permission.declined?
  end

  test "granting_user cannot decline a trustee grant they granted" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @user,
      trustee_user: @other_user,
      permissions: { "create_note" => true },
    )

    post "/u/#{@user.handle}/settings/trustee-authorizations/#{permission.truncated_id}/actions/decline_trustee_authorization",
      headers: @headers

    assert_response :forbidden
    assert_includes response.body, "You can only decline trustee authorizations granted to you"

    permission.reload
    assert permission.pending?
  end

  # === Revoke Tests ===

  test "granting_user can revoke an active trustee grant" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @user,
      trustee_user: @other_user,
      permissions: { "create_note" => true },
    )
    permission.accept!

    post "/u/#{@user.handle}/settings/trustee-authorizations/#{permission.truncated_id}/actions/revoke_trustee_authorization",
      headers: @headers

    assert_response :success
    assert_includes response.body, "Trustee authorization revoked"

    permission.reload
    assert permission.revoked?
  end

  test "granting_user can revoke a pending trustee grant" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @user,
      trustee_user: @other_user,
      permissions: { "create_note" => true },
    )

    post "/u/#{@user.handle}/settings/trustee-authorizations/#{permission.truncated_id}/actions/revoke_trustee_authorization",
      headers: @headers

    assert_response :success
    assert_includes response.body, "Trustee authorization revoked"

    permission.reload
    assert permission.revoked?
  end

  test "trustee_user cannot revoke a trustee grant" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @other_user,
      trustee_user: @user,
      permissions: { "create_note" => true },
    )
    permission.accept!

    post "/u/#{@user.handle}/settings/trustee-authorizations/#{permission.truncated_id}/actions/revoke_trustee_authorization",
      headers: @headers

    assert_response :forbidden
    assert_includes response.body, "You can only revoke trustee authorizations you created"

    permission.reload
    assert permission.active?
  end

  test "cannot revoke already revoked trustee grant" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @user,
      trustee_user: @other_user,
      permissions: { "create_note" => true },
    )
    permission.accept!
    permission.revoke!

    post "/u/#{@user.handle}/settings/trustee-authorizations/#{permission.truncated_id}/actions/revoke_trustee_authorization",
      headers: @headers

    assert_response :conflict
    assert_includes response.body, "already revoked"
  end

  # === Authorization Tests ===

  test "user cannot view trustee grants for other user" do
    get "/u/#{@other_user.handle}/settings/trustee-authorizations", headers: @headers
    assert_response :forbidden
    assert_includes response.body, "You don't have permission"
  end

  test "user cannot create trustee grant for other user" do
    third_user = create_user(email: "third_#{SecureRandom.hex(4)}@example.com", name: "Third User")
    @tenant.add_user!(third_user)

    assert_no_difference "TrusteeGrant.unscoped.count" do
      post "/u/#{@other_user.handle}/settings/trustee-authorizations/new/actions/create_trustee_authorization",
        params: {
          trustee_user_id: third_user.id,
          permissions: ["create_note"],
        }.to_json,
        headers: @headers
    end

    assert_response :forbidden
  end

  # === Actions Index Tests ===

  test "actions index shows accept/decline for pending received trustee grant" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @other_user,
      trustee_user: @user,
      permissions: { "create_note" => true },
    )

    get "/u/#{@user.handle}/settings/trustee-authorizations/#{permission.truncated_id}/actions", headers: @headers
    assert_response :success
    assert_includes response.body, "accept_trustee_authorization"
    assert_includes response.body, "decline_trustee_authorization"
    assert_not_includes response.body, "revoke_trustee_authorization"
  end

  test "actions index shows revoke for granted trustee grant" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @user,
      trustee_user: @other_user,
      permissions: { "create_note" => true },
    )

    get "/u/#{@user.handle}/settings/trustee-authorizations/#{permission.truncated_id}/actions", headers: @headers
    assert_response :success
    assert_includes response.body, "revoke_trustee_authorization"
    assert_not_includes response.body, "accept_trustee_authorization"
    assert_not_includes response.body, "decline_trustee_authorization"
  end

  test "actions index shows no actions for revoked trustee grant" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @user,
      trustee_user: @other_user,
      permissions: { "create_note" => true },
    )
    permission.revoke!

    get "/u/#{@user.handle}/settings/trustee-authorizations/#{permission.truncated_id}/actions", headers: @headers
    assert_response :success
    assert_not_includes response.body, "accept_trustee_authorization"
    assert_not_includes response.body, "decline_trustee_authorization"
    assert_not_includes response.body, "revoke_trustee_authorization"
  end
end
