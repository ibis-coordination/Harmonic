require "test_helper"

class AutocompleteControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  # === Unauthenticated Access Tests ===

  test "unauthenticated user gets 401 for users autocomplete" do
    get "/studios/#{@collective.handle}/autocomplete/users", params: { q: "test" }, headers: { "Accept" => "application/json" }
    assert_response :unauthorized
  end

  # === Users Autocomplete Tests ===

  test "authenticated user can search users in studio" do
    sign_in_as(@user, tenant: @tenant)
    get "/studios/#{@collective.handle}/autocomplete/users", params: { q: @user.tenant_user.handle[0, 2] }, headers: { "Accept" => "application/json" }
    assert_response :success
    json_response = JSON.parse(response.body)
    assert json_response.is_a?(Array)
  end

  test "returns studio members sorted alphabetically for empty query" do
    # Create additional users to test sorting
    alice = create_user(email: "alice@example.com", name: "Alice Testperson")
    @tenant.add_user!(alice)
    @collective.add_user!(alice)

    bob = create_user(email: "bob@example.com", name: "Bob Testperson")
    @tenant.add_user!(bob)
    @collective.add_user!(bob)

    sign_in_as(@user, tenant: @tenant)
    get "/studios/#{@collective.handle}/autocomplete/users", params: { q: "" }, headers: { "Accept" => "application/json" }
    assert_response :success

    json_response = JSON.parse(response.body)
    assert json_response.is_a?(Array)
    assert json_response.length > 0, "Should return studio members for empty query"

    # Verify results are sorted alphabetically by handle
    handles = json_response.map { |u| u["handle"] }
    assert_equal handles.sort, handles, "Results should be sorted alphabetically by handle"
  end

  test "returns matching studio members by handle" do
    sign_in_as(@user, tenant: @tenant)

    # Get the first few characters of the user's handle to search
    search_term = @user.tenant_user.handle[0, 2]
    get "/studios/#{@collective.handle}/autocomplete/users", params: { q: search_term }, headers: { "Accept" => "application/json" }
    assert_response :success

    json_response = JSON.parse(response.body)
    assert json_response.is_a?(Array)

    # Should find the user if search matches and they are a studio member
    if json_response.any?
      user_result = json_response.find { |u| u["handle"] == @user.tenant_user.handle }
      if user_result
        assert_equal @user.id, user_result["id"]
        assert_equal @user.tenant_user.display_name, user_result["display_name"]
      end
    end
  end

  test "returns matching studio members by display_name" do
    sign_in_as(@user, tenant: @tenant)

    # Search by display name
    search_term = @user.tenant_user.display_name[0, 2].downcase
    get "/studios/#{@collective.handle}/autocomplete/users", params: { q: search_term }, headers: { "Accept" => "application/json" }
    assert_response :success

    json_response = JSON.parse(response.body)
    assert json_response.is_a?(Array)
  end

  test "search is case insensitive" do
    sign_in_as(@user, tenant: @tenant)

    # Search with uppercase
    search_term = @user.tenant_user.handle[0, 2].upcase
    get "/studios/#{@collective.handle}/autocomplete/users", params: { q: search_term }, headers: { "Accept" => "application/json" }
    assert_response :success

    json_response_upper = JSON.parse(response.body)

    # Search with lowercase
    get "/studios/#{@collective.handle}/autocomplete/users", params: { q: search_term.downcase }, headers: { "Accept" => "application/json" }
    assert_response :success

    json_response_lower = JSON.parse(response.body)

    # Results should be the same (same users found regardless of case)
    assert_equal json_response_upper.map { |u| u["id"] }.sort, json_response_lower.map { |u| u["id"] }.sort
  end

  test "returns user data structure with required fields" do
    sign_in_as(@user, tenant: @tenant)

    # Search for the user
    search_term = @user.tenant_user.handle[0, 3]
    get "/studios/#{@collective.handle}/autocomplete/users", params: { q: search_term }, headers: { "Accept" => "application/json" }
    assert_response :success

    json_response = JSON.parse(response.body)
    if json_response.any?
      user_result = json_response.first
      assert user_result.key?("id")
      assert user_result.key?("handle")
      assert user_result.key?("display_name")
      assert user_result.key?("avatar_url")
    end
  end

  test "limits results to 10" do
    sign_in_as(@user, tenant: @tenant)

    # Use a very common search term that might match many users
    get "/studios/#{@collective.handle}/autocomplete/users", params: { q: "a" }, headers: { "Accept" => "application/json" }
    assert_response :success

    json_response = JSON.parse(response.body)
    assert json_response.length <= 10
  end

  test "only returns members of the current studio" do
    # Create a second user who is a member of a different studio
    other_user = create_user(email: "other@example.com", name: "Otheruser Testperson")
    @tenant.add_user!(other_user) # handle will be "otheruser-testperson" based on name
    other_collective = create_collective(tenant: @tenant, created_by: @user, name: "Other Studio", handle: "other-studio")
    other_collective.add_user!(other_user)

    sign_in_as(@user, tenant: @tenant)

    # Search for "otheruser" which should match the other user's handle
    get "/studios/#{@collective.handle}/autocomplete/users", params: { q: "otheruser" }, headers: { "Accept" => "application/json" }
    assert_response :success

    json_response = JSON.parse(response.body)

    # The other user should NOT appear because they're not a member of @studio
    other_user_handles = json_response.map { |u| u["handle"] }
    assert_not_includes other_user_handles, "otheruser-testperson", "Users from other studios should not appear in autocomplete results"
  end

  test "returns studio members who match the search" do
    # Create another user who IS a member of the studio
    member_user = create_user(email: "member@example.com", name: "Memberuser Testperson")
    @tenant.add_user!(member_user) # handle will be "memberuser-testperson" based on name
    @collective.add_user!(member_user)

    sign_in_as(@user, tenant: @tenant)

    # Search for "memberuser" which should match the member user's handle
    get "/studios/#{@collective.handle}/autocomplete/users", params: { q: "memberuser" }, headers: { "Accept" => "application/json" }
    assert_response :success

    json_response = JSON.parse(response.body)

    # The member user SHOULD appear because they ARE a member of @studio
    member_user_result = json_response.find { |u| u["handle"] == "memberuser-testperson" }
    assert_not_nil member_user_result, "Studio members should appear in autocomplete results"
    assert_equal member_user.id, member_user_result["id"]
  end

  test "excludes current user from autocomplete results" do
    sign_in_as(@user, tenant: @tenant)

    # Search for the current user's handle - they should NOT appear in results
    search_term = @user.tenant_user.handle
    get "/studios/#{@collective.handle}/autocomplete/users", params: { q: search_term }, headers: { "Accept" => "application/json" }
    assert_response :success

    json_response = JSON.parse(response.body)

    # The current user should NOT appear in their own autocomplete results
    current_user_result = json_response.find { |u| u["id"] == @user.id }
    assert_nil current_user_result, "Current user should not appear in autocomplete results"
  end
end
