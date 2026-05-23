# typed: false

require "test_helper"

# Confirms that the /rails/active_storage/direct_uploads endpoint goes
# through ApplicationController's auth chain (login required, suspension,
# activation gate, billing/archive gates). The whole point of overriding
# the route is to inherit those gates automatically — these tests guard
# the override.
class DirectUploadsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"

    @valid_blob_params = {
      blob: {
        filename: "a.png",
        byte_size: 1024,
        checksum: Digest::MD5.base64digest("test"),
        content_type: "image/png",
      },
    }
  end

  test "unauthenticated request is rejected (does not create a blob)" do
    assert_no_difference -> { ActiveStorage::Blob.count } do
      post "/rails/active_storage/direct_uploads", params: @valid_blob_params
    end
    # ApplicationController bounces unauth requests to login/auth flow;
    # we just need to confirm no blob row was created.
    assert response.redirect? || response.unauthorized? || response.forbidden?,
           "expected an auth-gated response, got #{response.status}"
  end

  test "authenticated request returns blob signed_id + direct_upload URL" do
    sign_in_as(@user, tenant: @tenant)

    assert_difference -> { ActiveStorage::Blob.count }, 1 do
      post "/rails/active_storage/direct_uploads", params: @valid_blob_params
    end
    assert_response :success
    body = JSON.parse(response.body)
    assert body["signed_id"].present?, "expected a signed_id"
    assert body.dig("direct_upload", "url").present?, "expected a direct_upload url"
  end

  test "oversized byte_size is rejected without creating a blob" do
    sign_in_as(@user, tenant: @tenant)
    huge = DirectUploadsController::MAX_DIRECT_UPLOAD_BYTES + 1

    assert_no_difference -> { ActiveStorage::Blob.count } do
      post "/rails/active_storage/direct_uploads",
           params: @valid_blob_params.deep_merge(blob: { byte_size: huge })
    end
    assert_response :content_too_large
  end

  test "zero / missing byte_size is rejected" do
    sign_in_as(@user, tenant: @tenant)

    assert_no_difference -> { ActiveStorage::Blob.count } do
      post "/rails/active_storage/direct_uploads",
           params: @valid_blob_params.deep_merge(blob: { byte_size: 0 })
    end
    assert_response :content_too_large
  end

  test "suspended user is rejected" do
    @user.update_columns(suspended_at: Time.current)
    sign_in_as(@user, tenant: @tenant, activate: false, add_to_tenant: false)

    assert_no_difference -> { ActiveStorage::Blob.count } do
      post "/rails/active_storage/direct_uploads", params: @valid_blob_params
    end
    assert_not response.successful?
  ensure
    @user.update_columns(suspended_at: nil)
  end
end
