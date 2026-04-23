require "test_helper"

class UserBlocksControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    @other_user = create_user(email: "blockable-#{SecureRandom.hex(4)}@example.com", name: "Blockable User")
    @tenant.add_user!(@other_user)
    @collective.add_user!(@other_user)
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  # === Unauthenticated Access ===

  test "unauthenticated user is redirected from user blocks index" do
    get "/user-blocks"
    assert_response :redirect
  end

  # === Index ===

  test "user can view their blocks list" do
    sign_in_as(@user, tenant: @tenant)
    UserBlock.create!(blocker: @user, blocked: @other_user, tenant: @tenant)

    get "/user-blocks"

    assert_response :success
    assert_match @other_user.name, response.body
  end

  # === Create ===

  test "user can block another user" do
    sign_in_as(@user, tenant: @tenant)

    assert_difference "UserBlock.count", 1 do
      post "/user-blocks", params: { blocked_id: @other_user.id }
    end

    assert_response :redirect
    assert UserBlock.where(blocker: @user, blocked: @other_user).exists?
  end

  test "user cannot block themselves" do
    sign_in_as(@user, tenant: @tenant)

    assert_no_difference "UserBlock.count" do
      post "/user-blocks", params: { blocked_id: @user.id }
    end

    assert_response :redirect
    assert_match "cannot block yourself", flash[:alert]
  end

  test "duplicate block does not create second record" do
    sign_in_as(@user, tenant: @tenant)
    UserBlock.create!(blocker: @user, blocked: @other_user, tenant: @tenant)

    assert_no_difference "UserBlock.count" do
      post "/user-blocks", params: { blocked_id: @other_user.id }
    end

    assert_response :redirect
  end

  # === Destroy ===

  test "user can unblock a user" do
    sign_in_as(@user, tenant: @tenant)
    user_block = UserBlock.create!(blocker: @user, blocked: @other_user, tenant: @tenant)

    assert_difference "UserBlock.count", -1 do
      delete "/user-blocks/#{user_block.id}"
    end

    assert_response :redirect
  end

  test "user cannot delete someone else's block" do
    sign_in_as(@user, tenant: @tenant)
    third_user = create_user(email: "third-#{SecureRandom.hex(4)}@example.com", name: "Third User")
    @tenant.add_user!(third_user)
    @collective.add_user!(third_user)
    user_block = UserBlock.create!(blocker: third_user, blocked: @other_user, tenant: @tenant)

    assert_no_difference "UserBlock.count" do
      delete "/user-blocks/#{user_block.id}"
    end

    assert_response :not_found
  end
end
