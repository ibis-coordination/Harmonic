# frozen_string_literal: true

require "test_helper"

class MarkdownPreviewsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = @global_tenant
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  test "renders markdown to sanitized HTML for an authenticated user" do
    sign_in_as(@user, tenant: @tenant)
    post "/markdown/preview", params: { text: "# Hello\n\n**bold**" }
    assert_response :success
    assert_includes @response.body, "<strong>bold</strong>"
  end

  test "strips dangerous markup via the shared renderer" do
    sign_in_as(@user, tenant: @tenant)
    post "/markdown/preview", params: { text: "<script>alert(1)</script> hi" }
    assert_response :success
    assert_not_includes @response.body, "<script>"
  end

  test "returns a placeholder when text is blank" do
    sign_in_as(@user, tenant: @tenant)
    post "/markdown/preview", params: { text: "   " }
    assert_response :success
    assert_includes @response.body, "Nothing to preview"
  end

  test "inline mode strips the wrapping paragraph" do
    sign_in_as(@user, tenant: @tenant)
    post "/markdown/preview", params: { text: "just text", inline: "true" }
    assert_response :success
    assert_not_includes @response.body, "<p>"
  end

  test "rejects text over the length cap" do
    sign_in_as(@user, tenant: @tenant)
    post "/markdown/preview", params: { text: "a" * (MarkdownPreviewsController::MAX_PREVIEW_LENGTH + 1) }
    assert_response :unprocessable_entity
    assert_includes @response.body, "Too much text"
  end

  test "inline fallback renders an inline span rather than a block paragraph" do
    sign_in_as(@user, tenant: @tenant)
    post "/markdown/preview", params: { text: "a" * (MarkdownPreviewsController::MAX_PREVIEW_LENGTH + 1), inline: "true" }
    assert_response :unprocessable_entity
    assert_includes @response.body, "<span"
    assert_not_includes @response.body, "<p"
  end

  test "block fallback renders a paragraph when not inline" do
    sign_in_as(@user, tenant: @tenant)
    post "/markdown/preview", params: { text: "a" * (MarkdownPreviewsController::MAX_PREVIEW_LENGTH + 1) }
    assert_response :unprocessable_entity
    assert_includes @response.body, "<p"
  end

  test "requires authentication" do
    post "/markdown/preview", params: { text: "hi" }
    assert_response :redirect
  end
end
