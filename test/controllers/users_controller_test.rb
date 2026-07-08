require "test_helper"

class UsersControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
  end

  # === Workspace Trio Settings View ===

  test "user settings page shows Workspace AI Assistant section when tenant has trio enabled" do
    @tenant.enable_feature_flag!("trio")
    sign_in_as(@user, tenant: @tenant)

    get "/settings"
    assert_response :success
    assert_includes response.body, "Workspace AI Assistant"
    assert_includes response.body, "feature_trio"
  end

  test "user settings page hides Workspace AI Assistant section when tenant has trio disabled" do
    @tenant.disable_feature_flag!("trio")
    sign_in_as(@user, tenant: @tenant)

    get "/settings"
    assert_response :success
    assert_not_includes response.body, "Workspace AI Assistant"
  end

  # === Workspace Trio Toggle ===

  test "workspace owner can enable Trio in their private workspace" do
    @tenant.enable_feature_flag!("trio")
    workspace = T.must(@user.private_workspace)
    workspace.set_feature_flag!("trio", false)
    upgrade_collective_to_paid!(workspace, owner: @user)

    sign_in_as(@user, tenant: @tenant)
    post "/settings/workspace_trio",
      params: { feature_trio: "true" },
      headers: { "HTTP_REFERER" => "http://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/settings" }

    workspace.reload
    assert_not_nil workspace.trio_user_id, "expected trio to be activated in workspace"
    assert AutomationRule.where(ai_agent_id: workspace.trio_user_id).exists?
  end

  # Self-hosted (non-billing) tenants have no tier model. A free-tier
  # workspace on such a tenant must still allow trio enablement — the
  # controller gate should use tier_unlocks_paid_features?, not paid_tier?.
  test "workspace owner can enable Trio on non-billing tenant without upgrading" do
    @tenant.enable_feature_flag!("trio")
    workspace = T.must(@user.private_workspace)
    workspace.set_feature_flag!("trio", false)
    # tier stays at free; no stripe_billing flag on the tenant

    sign_in_as(@user, tenant: @tenant)
    post "/settings/workspace_trio",
      params: { feature_trio: "true" },
      headers: { "HTTP_REFERER" => "http://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/settings" }

    workspace.reload
    assert_not_nil workspace.trio_user_id, "self-hosted: trio should activate on free workspace"
  end

  test "workspace owner can disable Trio in their private workspace" do
    @tenant.enable_feature_flag!("trio")
    workspace = T.must(@user.private_workspace)
    upgrade_collective_to_paid!(workspace, owner: @user)
    workspace.set_feature_flag!("trio", true)
    TrioActivator.activate!(workspace)
    trio_id = T.must(workspace.reload.trio_user_id)

    sign_in_as(@user, tenant: @tenant)
    post "/settings/workspace_trio",
      params: { feature_trio: "false" },
      headers: { "HTTP_REFERER" => "http://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/settings" }

    workspace.reload
    assert_nil workspace.trio_user_id, "expected trio to be deactivated in workspace"
    assert AutomationRule.where(ai_agent_id: trio_id).none? { |r| r.enabled? }
  end

  test "the handle-free workspace-trio route only toggles the signed-in user's workspace" do
    other_user = create_user(name: "Other User")
    @tenant.add_user!(other_user)
    @tenant.enable_feature_flag!("trio")

    sign_in_as(other_user, tenant: @tenant)
    post "/settings/workspace_trio",
      params: { feature_trio: "true" },
      headers: { "HTTP_REFERER" => "http://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/settings" }

    # No handle in the route: the toggle applies to other_user's own workspace,
    # so @user's workspace is structurally untouchable here.
    assert_nil T.must(@user.private_workspace).reload.trio_user_id
  end

  # === Workspace Trio paid-tier gate ===

  test "workspace owner is blocked from enabling Trio on a free workspace" do
    enable_stripe_billing_flag!(@tenant)
    @tenant.enable_feature_flag!("trio")
    workspace = T.must(@user.private_workspace)
    workspace.set_feature_flag!("trio", false)

    sign_in_as(@user, tenant: @tenant)
    post "/settings/workspace_trio",
      params: { feature_trio: "true" },
      headers: { "HTTP_REFERER" => "http://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/settings" }

    workspace.reload
    assert_nil workspace.trio_user_id, "trio should not be activated on a free workspace"
    assert flash[:error].to_s.downcase.include?("paid")
  end

  test "workspace owner can enable Trio when workspace is on the paid tier" do
    enable_stripe_billing_flag!(@tenant)
    @tenant.enable_feature_flag!("trio")
    workspace = T.must(@user.private_workspace)
    workspace.set_feature_flag!("trio", false)
    upgrade_collective_to_paid!(workspace, owner: @user)

    sign_in_as(@user, tenant: @tenant)
    post "/settings/workspace_trio",
      params: { feature_trio: "true" },
      headers: { "HTTP_REFERER" => "http://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/settings" }

    workspace.reload
    assert_not_nil workspace.trio_user_id, "trio should activate when workspace is paid"
  end

  test "workspace owner can always disable Trio (no paid-tier requirement on disable)" do
    enable_stripe_billing_flag!(@tenant)
    @tenant.enable_feature_flag!("trio")
    workspace = T.must(@user.private_workspace)
    upgrade_collective_to_paid!(workspace, owner: @user)
    workspace.set_feature_flag!("trio", true)
    TrioActivator.activate!(workspace)

    sign_in_as(@user, tenant: @tenant)
    post "/settings/workspace_trio",
      params: { feature_trio: "false" },
      headers: { "HTTP_REFERER" => "http://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/settings" }

    workspace.reload
    assert_nil workspace.trio_user_id
  end

  private

  def enable_stripe_billing_flag!(tenant)
    FeatureFlagService.config["stripe_billing"] ||= {}
    FeatureFlagService.config["stripe_billing"]["app_enabled"] = true
    tenant.enable_feature_flag!("stripe_billing")
  end

  public

  # === Profile Updates ===

  test "update_profile ignores system_role param" do
    # `system_role: "trio"` would grant the user system-agent privileges
    # (billing exemption, workspace membership exception, reserved handle).
    # update_profile does not accept this attribute.
    sign_in_as(@user, tenant: @tenant)
    refute @user.system?

    post "/settings/profile",
      params: { name: "Renamed", system_role: "trio" }

    @user.reload
    assert_nil @user.system_role
    refute @user.system?
  end

  test "update_profile cannot rename a non-trio user's handle to 'trio'" do
    sign_in_as(@user, tenant: @tenant)
    original_handle = @user.tenant_user.handle

    # TenantUser's reserved-handle validation raises ActiveRecord::RecordInvalid
    # at the update! call site. What matters for security is that the handle
    # is not persisted as "trio".
    begin
      post "/settings/profile", params: { new_handle: "trio" }
    rescue ActiveRecord::RecordInvalid
      # Expected — validation rejected the change.
    end

    @user.tenant_user.reload
    assert_equal original_handle, @user.tenant_user.handle
  end

  # === Show (GET /u/:handle) Tests ===

  test "can view user profile" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_includes response.body, @user.display_name
  end

  test "can view user profile in markdown format" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "# User: #{@user.display_name}"
  end

  # === Tabs on /u/:handle ===

  test "profile page renders a tab nav with Posts, Activity, Lists, and (when viewing other w/ commons) Common Collectives" do
    other = create_user(email: "other-tab-viewer@example.com", name: "Other Viewer")
    @tenant.add_user!(other)
    common = Collective.create!(
      tenant: @tenant, name: "Common", handle: "common-#{SecureRandom.hex(4)}",
      collective_type: "standard", created_by: @user, updated_by: @user
    )
    common.add_user!(@user)
    common.add_user!(other)

    sign_in_as(other, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_select "nav.pulse-profile-tabs"
    assert_select "nav.pulse-profile-tabs a", text: /Posts/
    assert_select "nav.pulse-profile-tabs a", text: /Activity/
    assert_select "nav.pulse-profile-tabs a", text: /Lists/
    assert_select "nav.pulse-profile-tabs a", text: /Common Collectives/
  end

  test "profile page hides Common Collectives tab when viewing own profile" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_select "nav.pulse-profile-tabs"
    assert_select "nav.pulse-profile-tabs a", text: /Common Collectives/, count: 0
  end

  test "profile page hides Common Collectives tab when no common collectives" do
    other = create_user(email: "no-common-viewer@example.com", name: "Other Viewer")
    @tenant.add_user!(other)
    sign_in_as(other, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_select "nav.pulse-profile-tabs a", text: /Common Collectives/, count: 0
  end

  test "profile page defaults to Posts tab" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_select "nav.pulse-profile-tabs a[aria-current=page]", text: /Posts/
  end

  test "Posts tab shows only post-subtype notes" do
    post_note = create_note(tenant: @tenant, collective: @tenant.main_collective, created_by: @user, title: "A Post", subtype: "post")
    reminder_note = create_note(tenant: @tenant, collective: @tenant.main_collective, created_by: @user, title: "A Reminder", subtype: "reminder")
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}?tab=posts"
    assert_response :success
    assert_select "nav.pulse-profile-tabs a[aria-current=page]", text: /Posts/
    assert_includes response.body, "A Post"
    assert_not_includes response.body, "A Reminder"
  end

  test "Activity tab excludes post-subtype notes; surfaces non-post notes" do
    post_note = create_note(tenant: @tenant, collective: @tenant.main_collective, created_by: @user, title: "A Post", subtype: "post")
    reminder_note = create_note(tenant: @tenant, collective: @tenant.main_collective, created_by: @user, title: "A Reminder", subtype: "reminder")
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}?tab=activity"
    assert_response :success
    assert_select "nav.pulse-profile-tabs a[aria-current=page]", text: /Activity/
    assert_not_includes response.body, "A Post"
    assert_includes response.body, "A Reminder"
  end

  test "Posts and Activity partition the legacy feed (union equals baseline, no overlap)" do
    main = @tenant.main_collective
    post = create_note(tenant: @tenant, collective: main, created_by: @user, title: "P", subtype: "post")
    reminder = create_note(tenant: @tenant, collective: main, created_by: @user, title: "R", subtype: "reminder")
    decision = create_decision(tenant: @tenant, collective: main, created_by: @user, question: "D?")
    commitment = create_commitment(tenant: @tenant, collective: main, created_by: @user, title: "C")

    baseline = FeedBuilder.new(
      notes_scope: Note.main_collective_scope(@tenant).where(created_by_id: @user.id),
      decisions_scope: Decision.main_collective_scope(@tenant).where(created_by_id: @user.id),
      commitments_scope: Commitment.main_collective_scope(@tenant).where(created_by_id: @user.id),
    ).feed_items

    posts_only = FeedBuilder.new(
      notes_scope: Note.main_collective_scope(@tenant).where(created_by_id: @user.id, subtype: "post"),
      decisions_scope: Decision.none,
      commitments_scope: Commitment.none,
    ).feed_items

    activity_only = FeedBuilder.new(
      notes_scope: Note.main_collective_scope(@tenant).where(created_by_id: @user.id).where.not(subtype: "post"),
      decisions_scope: Decision.main_collective_scope(@tenant).where(created_by_id: @user.id),
      commitments_scope: Commitment.main_collective_scope(@tenant).where(created_by_id: @user.id),
    ).feed_items

    baseline_ids   = baseline.map { |i| [i[:type], i[:item].id] }.to_set
    posts_ids      = posts_only.map { |i| [i[:type], i[:item].id] }.to_set
    activity_ids   = activity_only.map { |i| [i[:type], i[:item].id] }.to_set

    assert_equal baseline_ids, (posts_ids | activity_ids), "posts ∪ activity must equal baseline feed"
    assert_empty (posts_ids & activity_ids), "no item may appear in both posts and activity"
    # Sanity: each fixture lands somewhere.
    assert_includes posts_ids,    ["Note", post.id]
    assert_includes activity_ids, ["Note", reminder.id]
    assert_includes activity_ids, ["Decision", decision.id]
    assert_includes activity_ids, ["Commitment", commitment.id]
  end

  test "markdown profile renders a Lists section when the owner has visible lists" do
    UserList.create!(
      creator: @user, owner: @user,
      tenant: @tenant, collective: @tenant.main_collective,
      name: "Reading",
    )
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_match(/^## Lists/, response.body)
    assert_match(/Reading/, response.body)
  end

  test "markdown profile renders both Posts and Activity sections inline" do
    post_note = create_note(tenant: @tenant, collective: @tenant.main_collective, created_by: @user, title: "MdPost", subtype: "post")
    reminder_note = create_note(tenant: @tenant, collective: @tenant.main_collective, created_by: @user, title: "MdReminder", subtype: "reminder")
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_match(/^## Posts/, response.body)
    assert_match(/^## Activity/, response.body)
    assert_includes response.body, "MdPost"
    assert_includes response.body, "MdReminder"
  end

  test "?tab=lists makes Lists the active tab and Activity feed isn't rendered" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}?tab=lists"
    assert_response :success
    assert_select "nav.pulse-profile-tabs a[aria-current=page]", text: /Lists/
    assert_select ".pulse-feed", count: 0
  end

  test "blocked-either-way profile shows no tab nav" do
    other = create_user(email: "blocked-tab-viewer@example.com", name: "Other Viewer")
    @tenant.add_user!(other)
    UserBlock.create!(blocker: other, blocked: @user, tenant: @tenant)
    sign_in_as(other, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_select "nav.pulse-profile-tabs", count: 0
  end

  test "markdown profile renders all sections inline regardless of ?tab" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}?tab=lists", headers: { "Accept" => "text/markdown" }
    assert_response :success
    # Markdown view ignores ?tab and renders all sections that have content.
    assert_no_match(/pulse-profile-tabs/, response.body)
  end

  # === "Joined" header line ===

  test "profile header shows the month and year the user joined the tenant" do
    tu = @user.tenant_users.find_by(tenant_id: @tenant.id)
    tu.update_column(:created_at, Time.zone.local(2024, 3, 15))
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_select ".pulse-user-member-since", text: /Joined March 2024/
    assert_select ".pulse-user-member-since svg.octicon-calendar"
  end

  test "profile markdown includes the joined month and year" do
    tu = @user.tenant_users.find_by(tenant_id: @tenant.id)
    tu.update_column(:created_at, Time.zone.local(2025, 1, 1))
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_match(/^Joined January 2025/, response.body)
  end

  # === Profile pic editor on /u/:handle ===

  test "profile page shows the image-cropper editor for the profile owner" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_select "[data-controller='image-cropper']"
    assert_select "form[action=?][method=?]", "/u/#{@user.handle}/image", "post"
    assert_select "input[name='cropped_image_data']"
  end

  test "profile page hides the image-cropper editor for a non-owner viewer" do
    other = create_user(email: "non-owner-viewer@example.com", name: "Non Owner")
    @tenant.add_user!(other)
    sign_in_as(other, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_select "[data-controller='image-cropper']", count: 0
    assert_select "form[action=?]", "/u/#{@user.handle}/image", count: 0
  end

  test "non-owner viewer can click the showing user's image to open a lightbox" do
    image = Vips::Image.black(100, 100) + [128, 64, 200]
    tempfile = Tempfile.new(["lightbox", ".png"])
    tempfile.close
    image.write_to_file(tempfile.path)
    @user.image.attach(io: File.open(tempfile.path), filename: "lightbox.png", content_type: "image/png")

    other = create_user(email: "lightbox-viewer@example.com", name: "Lightbox Viewer")
    @tenant.add_user!(other)
    sign_in_as(other, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_select "button.pulse-user-avatar-lightbox[data-controller='lightbox']"
    assert_select "button.pulse-user-avatar-lightbox[data-action*='lightbox#open']"
  end

  test "lightbox trigger is absent when the showing user has no uploaded image" do
    other = create_user(email: "no-image-viewer@example.com", name: "No Image Viewer")
    @tenant.add_user!(other)
    sign_in_as(other, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_select "button.pulse-user-avatar-lightbox", count: 0
  end

  # === TenantUser profile fields: bio / location / website ===

  test "profile HTML shows bio, location, website when set on the viewed user's TenantUser" do
    tu = @user.tenant_users.find_by(tenant_id: @tenant.id)
    tu.update!(
      bio: "Likes long walks on the gradient.",
      location: "Seattle, WA",
      website: "https://example.com/me",
    )
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_includes response.body, "Likes long walks on the gradient."
    assert_includes response.body, "Seattle, WA"
    assert_select "a.pulse-user-website a, .pulse-user-website a" do
      assert_select "[href=?]", "https://example.com/me"
      assert_select "[rel*=nofollow]"
    end
  end

  test "profile HTML hides the profile info block when all three fields are blank" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_select ".pulse-user-profile-info", count: 0
  end

  test "profile HTML hides the profile info block when blocked either way" do
    tu = @user.tenant_users.find_by(tenant_id: @tenant.id)
    tu.update!(bio: "Hidden when blocked")
    other = create_user(email: "blocked-bio-viewer@example.com", name: "Blocked Viewer")
    @tenant.add_user!(other)
    UserBlock.create!(blocker: other, blocked: @user, tenant: @tenant)
    sign_in_as(other, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_select ".pulse-user-profile-info", count: 0
  end

  test "profile markdown renders bio + location + website" do
    tu = @user.tenant_users.find_by(tenant_id: @tenant.id)
    tu.update!(
      bio: "Md bio body.",
      location: "Md Location",
      website: "https://md.example.com",
    )
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "Md bio body."
    assert_match(/^Location: Md Location/, response.body)
    assert_match(%r{^Website: https://md\.example\.com}, response.body)
  end

  test "update_profile persists bio / location / website to TenantUser" do
    sign_in_as(@user, tenant: @tenant)
    post "/settings/profile", params: {
      bio: "Updated bio",
      location: "New York",
      website: "https://updated.example.com",
    }
    assert_response :redirect
    tu = @user.tenant_users.find_by(tenant_id: @tenant.id)
    assert_equal "Updated bio", tu.bio
    assert_equal "New York", tu.location
    assert_equal "https://updated.example.com", tu.website
  end

  test "update_profile rejects an invalid website scheme and redirects with an error" do
    sign_in_as(@user, tenant: @tenant)
    post "/settings/profile", params: { website: "javascript:alert(1)" }
    assert_response :redirect
    follow_redirect!
    assert_match(/http or https/i, response.body)
    tu = @user.tenant_users.find_by(tenant_id: @tenant.id)
    assert_nil tu.website
  end

  test "settings page renders the bio / location / website form fields" do
    sign_in_as(@user, tenant: @tenant)
    get "/settings"
    assert_response :success
    assert_select "textarea[name=?]", "bio"
    assert_select "input[name=?]", "location"
    assert_select "input[name=?][type=?]", "website", "url"
  end

  # === Tune-in buttons on /u/:handle/mutuals ===

  def add_to_primary_list(list:, member:, added_by:)
    list.user_list_members.create!(
      tenant:     list.tenant,
      collective: list.collective,
      added_by:   added_by,
      user:       member,
    )
  end

  test "another user's mutuals page shows a tune-in button next to each non-self mutual" do
    main = @tenant.main_collective
    main.add_user!(@user) unless main.user_is_member?(@user)
    other = create_user(email: "tu-mutuals-other@example.com", name: "Other")
    @tenant.add_user!(other); main.add_user!(other)
    third = create_user(email: "tu-mutuals-third@example.com", name: "Third Person")
    @tenant.add_user!(third); main.add_user!(third)
    # @other ↔ third are mutuals.
    add_to_primary_list(list: other.primary_user_list_in!(@tenant), member: third, added_by: other)
    add_to_primary_list(list: third.primary_user_list_in!(@tenant), member: other, added_by: third)

    sign_in_as(@user, tenant: @tenant)
    get "/u/#{other.handle}/mutuals"
    assert_response :success
    # @user is not yet tuned in to `third` — should see a Tune in button on third's row.
    assert_select ".pulse-list-members .pulse-tune-in-btn", text: /Tune in/
  end

  test "your own mutuals page hides the tune-in button (every row is already reciprocal)" do
    main = @tenant.main_collective
    main.add_user!(@user) unless main.user_is_member?(@user)
    other = create_user(email: "own-mutuals-other@example.com", name: "Other")
    @tenant.add_user!(other); main.add_user!(other)
    # @user ↔ other are mutuals.
    add_to_primary_list(list: @user.primary_user_list_in!(@tenant), member: other, added_by: @user)
    add_to_primary_list(list: other.primary_user_list_in!(@tenant), member: @user, added_by: other)

    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}/mutuals"
    assert_response :success
    assert_select ".pulse-tune-in-btn", count: 0
  end

  test "profile page does not render a Social Proximity section (HTML)" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_no_match(/Social Proximity/, response.body)
  end

  test "profile page does not render a Social Proximity section (markdown)" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_no_match(/Social Proximity/, response.body)
  end

  # === AiAgent Count Tests (HTML) ===

  test "person user profile shows ai_agent count when they have ai_agents" do
    ai_agent1 = create_ai_agent(parent: @user, name: "AiAgent One")
    ai_agent2 = create_ai_agent(parent: @user, name: "AiAgent Two")
    @tenant.add_user!(ai_agent1)
    @tenant.add_user!(ai_agent2)

    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_includes response.body, "Has 2 AI agents"
  end

  test "person user profile shows singular ai_agent when they have one" do
    ai_agent = create_ai_agent(parent: @user, name: "Only AiAgent")
    @tenant.add_user!(ai_agent)

    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_includes response.body, "Has 1 AI agent"
    assert_not_includes response.body, "Has 1 AI agents"
  end

  test "person user profile does not show ai_agent count when they have none" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_not_includes response.body, "Has 0 AI agent"
    # The profile section should not mention AI agents when user has none
    assert_no_match(/Has \d+ AI agent/, response.body)
  end

  test "ai_agent profile does not show ai_agent count" do
    ai_agent = create_ai_agent(parent: @user, name: "Test AiAgent")
    @tenant.add_user!(ai_agent)
    @collective.add_user!(ai_agent)

    sign_in_as(@user, tenant: @tenant)
    get "/u/#{ai_agent.handle}"
    assert_response :success
    # AiAgent shows "AI agent" badge and "Managed by" but not "Has N AI agents"
    assert_includes response.body, "AI agent"
    assert_not_includes response.body, "Has 0 AI agent"
    assert_not_includes response.body, "Has 1 AI agent"
  end

  # === AiAgent Count Tests (Markdown) ===

  test "markdown person profile shows ai_agent count when they have ai_agents" do
    ai_agent1 = create_ai_agent(parent: @user, name: "AiAgent One")
    ai_agent2 = create_ai_agent(parent: @user, name: "AiAgent Two")
    @tenant.add_user!(ai_agent1)
    @tenant.add_user!(ai_agent2)

    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "Has 2 AI agents"
  end

  test "markdown person profile does not show ai_agent count when they have none" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_not_includes response.body, "Has 0 AI agent"
  end

  # === AiAgent Count Scoping Tests ===

  # === /u/<agent>/settings redirects to /ai-agents/<handle>/settings ===
  # AI agents have a single canonical settings surface; visits to the
  # user-settings URL for an agent redirect to the canonical page.

  test "GET /u/<agent>/settings redirects to /ai-agents/<handle>/settings for AI agents" do
    @tenant.enable_feature_flag!("internal_ai_agents")
    @tenant.enable_feature_flag!("external_ai_agents")
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    ai_agent = create_ai_agent(parent: @user, name: "Redirect Test Agent")
    @tenant.add_user!(ai_agent)
    handle = ai_agent.tenant_users.find_by(tenant: @tenant).handle
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    sign_in_as(@user, tenant: @tenant)
    get "/u/#{handle}/settings"
    assert_redirected_to "/ai-agents/#{handle}/settings"
  end

  test "GET /u/<agent>/settings.md redirects to /ai-agents/<handle>/settings.md for AI agents" do
    @tenant.enable_api!
    @tenant.enable_feature_flag!("internal_ai_agents")
    @tenant.enable_feature_flag!("external_ai_agents")
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    ai_agent = create_ai_agent(parent: @user, name: "Redirect MD Test Agent")
    @tenant.add_user!(ai_agent)
    handle = ai_agent.tenant_users.find_by(tenant: @tenant).handle
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    api_token = ApiToken.create!(
      user: @user,
      tenant: @tenant,
      name: "Redirect MD Test #{SecureRandom.hex(4)}",
      scopes: ApiToken.read_scopes,
    )
    get "/u/#{handle}/settings",
      headers: {
        "Accept" => "text/markdown",
        "Authorization" => "Bearer #{api_token.plaintext_token}",
      }
    assert_response :redirect
    assert_match %r{/ai-agents/#{handle}/settings}, response.headers["Location"]
  end

  test "GET /ai-agents/<handle>/settings includes the profile image upload" do
    @tenant.enable_feature_flag!("internal_ai_agents")
    @tenant.enable_feature_flag!("external_ai_agents")
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    ai_agent = create_ai_agent(parent: @user, name: "Profile Image Test Agent")
    @tenant.add_user!(ai_agent)
    handle = ai_agent.tenant_users.find_by(tenant: @tenant).handle
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/#{handle}/settings"
    assert_response :success
    assert_match(/Profile Image/i, response.body,
      "agent settings should include profile image upload — the only thing previously unique to /u/<agent>/settings")
  end

  test "POST /u/<agent>/settings/profile redirects to the canonical agent settings and mutates nothing" do
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    ai_agent = create_ai_agent(parent: @user, name: "Profile POST Test Agent")
    ai_agent.update_columns(agent_configuration: { "mode" => "external", "capabilities" => ["create_note"] })
    @tenant.add_user!(ai_agent)
    handle = ai_agent.tenant_users.find_by(tenant: @tenant).handle
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    sign_in_as(@user, tenant: @tenant)
    # The user-settings profile POST is now handle-free (/settings/profile) and
    # only ever edits the signed-in human. The legacy agent path 308-redirects to
    # the agent's canonical settings surface; the redirect is not followed here,
    # so nothing on the agent changes.
    post "/u/#{handle}/settings/profile", params: {
      name: "Updated Name",
      mode: "internal",
      capabilities: [""],
      identity_prompt: "ignored",
    }
    assert_response :redirect
    assert_match %r{/ai-agents/#{handle}/settings}, response.headers["Location"]
    ai_agent.reload
    assert_equal "Profile POST Test Agent", ai_agent.name, "agent name must be untouched"
    assert_equal "external", ai_agent.agent_configuration["mode"]
    assert_equal ["create_note"], ai_agent.agent_configuration["capabilities"]
    assert_nil ai_agent.agent_configuration["identity_prompt"]
  end

  test "ai_agent count only includes ai_agents in current tenant" do
    # Create two ai_agents
    ai_agent1 = create_ai_agent(parent: @user, name: "AiAgent In Tenant")
    ai_agent2 = create_ai_agent(parent: @user, name: "AiAgent Not In Tenant")

    # Only add ai_agent1 to the current tenant
    @tenant.add_user!(ai_agent1)
    # ai_agent2 is not added to the tenant

    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    # Should only show 1 AI agent (the one in this tenant)
    assert_includes response.body, "Has 1 AI agent"
    assert_not_includes response.body, "Has 2 AI agents"
  end

  # === Notification preferences ===

  test "settings page renders the notification preferences matrix" do
    sign_in_as(@user, tenant: @tenant)

    get "/settings"

    assert_response :success
    assert_includes response.body, "Notification preferences"
    assert_includes response.body, "notifications[comment][email]"
  end

  test "POST settings/notifications writes the full matrix and treats unchecked boxes as off" do
    sign_in_as(@user, tenant: @tenant)

    # Submit only two boxes checked. mention/email defaults to true and is now
    # absent from the payload, so the complete-matrix write must turn it off.
    post "/settings/notifications",
      params: { notifications: { comment: { email: "true" }, mention: { in_app: "true" } } }

    assert_response :redirect
    tu = @user.tenant_users.find_by(tenant: @tenant)
    assert tu.notification_enabled?("comment", "email")
    refute tu.notification_enabled?("comment", "in_app"), "unchecked box recorded as off"
    refute tu.notification_enabled?("mention", "email"), "omitted box recorded as off"
    assert tu.notification_enabled?("mention", "in_app")
  end

  test "form save does not record web_push:false when push is unavailable on the tenant" do
    # The form omits the Push column when push isn't available, so the
    # complete-matrix write must not treat those absent boxes as unchecked —
    # otherwise one save permanently opts the user out before push ever
    # launches on the tenant.
    sign_in_as(@user, tenant: @tenant)

    post "/settings/notifications",
      params: { notifications: { mention: { in_app: "true", email: "true" } } }

    assert_response :redirect
    tu = @user.tenant_users.find_by(tenant: @tenant)
    stored = tu.settings["notification_preferences"]
    refute stored.values.any? { |channels| channels.key?("web_push") },
           "web_push must not be written while the column isn't rendered"

    # Once push becomes available and a device is registered, the default
    # (on) must still apply.
    enable_web_push!(@tenant)
    WebPushSubscription.upsert_for!(
      user: @user, endpoint: "https://push.example.com/send/later", p256dh_key: "k", auth_key: "a"
    )
    assert_includes tu.reload.notification_channels_for("mention"), "web_push"
  end

  test "form save records unchecked web_push boxes when push is available" do
    sign_in_as(@user, tenant: @tenant)
    enable_web_push!(@tenant)
    WebPushSubscription.upsert_for!(
      user: @user, endpoint: "https://push.example.com/send/here", p256dh_key: "k", auth_key: "a"
    )

    # Full form submit with the Push column rendered but mention/web_push unchecked.
    post "/settings/notifications",
      params: { notifications: { mention: { in_app: "true", email: "true" } } }

    tu = @user.tenant_users.find_by(tenant: @tenant)
    refute_includes tu.notification_channels_for("mention"), "web_push",
                    "an unchecked Push box on a push-enabled tenant is a real opt-out"
  end

  test "markdown settings shows the Push column when push is available" do
    sign_in_as(@user, tenant: @tenant)
    enable_web_push!(@tenant)

    get "/settings", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match(/\| Type \| In-app \| Email \| Push \|/, response.body,
                 "agents must be able to read the web_push state they can write")
  end

  test "markdown settings omits the Push column when push is unavailable" do
    sign_in_as(@user, tenant: @tenant)

    get "/settings", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match(/\| Type \| In-app \| Email \|/, response.body)
    assert_no_match(/\| Push \|/, response.body)
  end

  test "markdown action update_notification_preferences merges only supplied keys" do
    sign_in_as(@user, tenant: @tenant)

    post "/settings/actions/update_notification_preferences",
      params: { notifications: { comment: { email: "true" } } },
      headers: { "Accept" => "text/markdown" }

    assert_response :success
    tu = @user.tenant_users.find_by(tenant: @tenant)
    assert tu.notification_enabled?("comment", "email"), "supplied toggle applied"
    assert tu.notification_enabled?("mention", "email"), "untouched type keeps its default"
  end

  test "the handle-free notification-preferences route updates the signed-in user's own prefs" do
    sign_in_as(@user, tenant: @tenant)
    post "/settings/notifications",
      params: { notifications: { comment: { email: "true" } } }

    # No handle to target: the update lands on @user's own preferences.
    tu = @user.tenant_users.find_by(tenant: @tenant)
    assert tu.notification_enabled?("comment", "email")
  end
end
