require "test_helper"

class MarkdownActionAuthorizationTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    @other_user = create_user(email: "other-#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(@other_user)
    @collective.add_user!(@other_user)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  # ==========================================
  # Note actions filtered by block
  # ==========================================

  test "note markdown frontmatter excludes confirm_read and add_comment when block exists" do
    note = create_note(text: "Test note", created_by: @other_user)
    UserBlock.create!(blocker: @other_user, blocked: @user, tenant: @tenant)

    sign_in_as(@user, tenant: @tenant)
    get note.path, headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_no_match(/confirm_read/, response.body)
    assert_no_match(/add_comment/, response.body)
  end

  test "note markdown frontmatter includes confirm_read and add_comment when no block" do
    note = create_note(text: "Test note", created_by: @other_user)

    sign_in_as(@user, tenant: @tenant)
    get note.path, headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match(/confirm_read/, response.body)
    assert_match(/add_comment/, response.body)
  end

  # ==========================================
  # Decision actions filtered by block
  # ==========================================

  test "decision markdown frontmatter excludes vote and add_options when block exists" do
    decision = create_decision(question: "Test?", created_by: @other_user)
    UserBlock.create!(blocker: @user, blocked: @other_user, tenant: @tenant)

    sign_in_as(@user, tenant: @tenant)
    get decision.path, headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_no_match(/^ {2}- name: vote$/m, response.body)
    assert_no_match(/^ {2}- name: add_options$/m, response.body)
  end

  test "decision markdown frontmatter includes vote and add_options when no block" do
    decision = create_decision(question: "Test?", created_by: @other_user)

    sign_in_as(@user, tenant: @tenant)
    get decision.path, headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match(/vote/, response.body)
    assert_match(/add_options/, response.body)
  end

  # ==========================================
  # Commitment actions filtered by block
  # ==========================================

  test "commitment markdown frontmatter excludes join_commitment when block exists" do
    commitment = create_commitment(title: "Test", created_by: @other_user)
    UserBlock.create!(blocker: @other_user, blocked: @user, tenant: @tenant)

    sign_in_as(@user, tenant: @tenant)
    get commitment.path, headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_no_match(/join_commitment/, response.body)
  end

  test "commitment markdown frontmatter includes join_commitment when no block" do
    commitment = create_commitment(title: "Test", created_by: @other_user)

    sign_in_as(@user, tenant: @tenant)
    get commitment.path, headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match(/join_commitment/, response.body)
  end

  # ==========================================
  # Actions index pages filtered by block
  # ==========================================

  test "note actions index excludes confirm_read when block exists" do
    note = create_note(text: "Test note", created_by: @other_user)
    UserBlock.create!(blocker: @other_user, blocked: @user, tenant: @tenant)

    sign_in_as(@user, tenant: @tenant)
    get "#{note.path}/actions", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_no_match(/confirm_read/, response.body)
  end

  test "note actions index includes confirm_read when no block" do
    note = create_note(text: "Test note", created_by: @other_user)

    sign_in_as(@user, tenant: @tenant)
    get "#{note.path}/actions", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match(/confirm_read/, response.body)
  end

  test "decision actions index excludes vote when block exists" do
    decision = create_decision(question: "Test?", created_by: @other_user)
    UserBlock.create!(blocker: @user, blocked: @other_user, tenant: @tenant)

    sign_in_as(@user, tenant: @tenant)
    get "#{decision.path}/actions", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_no_match(/vote/, response.body)
  end

  test "commitment actions index excludes join_commitment when block exists" do
    commitment = create_commitment(title: "Test", created_by: @other_user)
    UserBlock.create!(blocker: @other_user, blocked: @user, tenant: @tenant)

    sign_in_as(@user, tenant: @tenant)
    get "#{commitment.path}/actions", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_no_match(/join_commitment/, response.body)
  end

  # ==========================================
  # Agent actions filtered by allow_public_writes
  # ==========================================
  #
  # The public-write guardrail (CapabilityCheck#public_writes_allowed?) denies
  # any restricted-agent write whose resolved audience is "public" when the
  # owner hasn't enabled allow_public_writes. Discovery must agree, or the
  # frontmatter advertises actions the gate will deny.

  def agent_token(allow_public_writes:)
    config = { "mode" => "external", "allow_public_writes" => allow_public_writes }
    agent = create_ai_agent(parent: @user, name: "Discovery Agent #{SecureRandom.hex(4)}",
                            agent_configuration: config)
    @tenant.add_user!(agent)
    @tenant.main_collective.add_user!(agent)
    ApiToken.create!(tenant: @tenant, user: agent, scopes: ApiToken.valid_scopes, token_type: "rest")
  end

  test "main-collective note frontmatter omits public-resolved actions when allow_public_writes is off" do
    @tenant.enable_api!
    main = @tenant.main_collective
    main.enable_api!
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: main.handle)
    note = create_note(tenant: @tenant, collective: main, created_by: @user, title: "main note")
    token = agent_token(allow_public_writes: false)

    get "/collectives/#{main.handle}/n/#{note.truncated_id}",
        headers: { "Accept" => "text/markdown", "Authorization" => "Bearer #{token.plaintext_token}" }

    assert_response :success
    assert_no_match(/visibility: public/, response.body,
                    "discovery advertised a public-resolved action the public-write gate will deny")
  end

  test "main-collective note frontmatter includes public-resolved actions when allow_public_writes is on" do
    @tenant.enable_api!
    main = @tenant.main_collective
    main.enable_api!
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: main.handle)
    note = create_note(tenant: @tenant, collective: main, created_by: @user, title: "main note")
    token = agent_token(allow_public_writes: true)

    get "/collectives/#{main.handle}/n/#{note.truncated_id}",
        headers: { "Accept" => "text/markdown", "Authorization" => "Bearer #{token.plaintext_token}" }

    assert_response :success
    assert_match(/visibility: public/, response.body,
                 "expected discovery to list public-resolved actions for an agent with public writes enabled")
  end
end
