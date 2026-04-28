require "test_helper"

class HelpPagesTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @user = @global_user
    @api_token = ApiToken.create!(
      user: @user,
      tenant: @tenant,
      name: "Help Test #{SecureRandom.hex(4)}",
      scopes: ApiToken.valid_scopes,
    )
    @md_headers = {
      "Accept" => "text/markdown",
      "Authorization" => "Bearer #{@api_token.plaintext_token}",
    }
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
    sign_in_as(@user, tenant: @tenant)
  end

  TOPICS = %w[privacy collectives notes reminder-notes table-notes decisions commitments cycles search links agents api].freeze

  # =========================================================================
  # HTML rendering
  # =========================================================================

  test "help index renders HTML" do
    get "/help"
    assert_response :success
    assert_includes response.body, "Help"
    assert_includes response.body, "/help/collectives"
    assert_includes response.body, "/help/privacy"
  end

  TOPICS.each do |topic|
    test "help #{topic} renders HTML" do
      get "/help/#{topic}"
      assert_response :success
      assert_includes response.body, "pulse-prose"
      # Should not contain YAML frontmatter from markdown layout
      refute_includes response.body, "---\napp: Harmonic"
    end
  end

  # =========================================================================
  # Markdown rendering
  # =========================================================================

  test "help index renders markdown" do
    get "/help", headers: @md_headers
    assert_response :success
    assert_includes response.body, "# Help"
    assert_includes response.body, "/help/collectives"
  end

  TOPICS.each do |topic|
    test "help #{topic} renders markdown" do
      get "/help/#{topic}", headers: @md_headers
      assert_response :success
      assert_match(/^# /, response.body)
    end
  end

  # =========================================================================
  # Content accuracy
  # =========================================================================

  test "help pages have no actions" do
    get "/help", headers: @md_headers
    assert_response :success
    refute_includes response.body, "actions:"
  end
end
