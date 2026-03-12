# typed: false

require "test_helper"

class StripeWebhooksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_webhook_secret = ENV["STRIPE_WEBHOOK_SECRET"]
    ENV["STRIPE_WEBHOOK_SECRET"] = "whsec_test123"
  end

  teardown do
    ENV["STRIPE_WEBHOOK_SECRET"] = @original_webhook_secret
  end

  test "receive with valid signature processes event" do
    payload = { type: "checkout.session.completed", data: { object: { customer: "cus_test", subscription: "sub_test" } } }.to_json
    timestamp = Time.now.to_i
    signature = generate_stripe_signature(payload, timestamp)

    # Create a matching StripeCustomer so the handler has something to process
    user = create_user(email: "webhook-test-#{SecureRandom.hex(4)}@example.com")
    StripeCustomer.create!(billable: user, stripe_id: "cus_test", active: false)

    post "/stripe/webhooks",
      params: payload,
      headers: {
        "CONTENT_TYPE" => "application/json",
        "HTTP_STRIPE_SIGNATURE" => "t=#{timestamp},v1=#{signature}",
      }

    assert_response :ok
  end

  test "receive with invalid signature returns 400" do
    payload = { type: "checkout.session.completed" }.to_json

    post "/stripe/webhooks",
      params: payload,
      headers: {
        "CONTENT_TYPE" => "application/json",
        "HTTP_STRIPE_SIGNATURE" => "t=123,v1=invalidsignature",
      }

    assert_response :bad_request
  end

  test "receive with missing signature returns 400" do
    payload = { type: "checkout.session.completed" }.to_json

    post "/stripe/webhooks",
      params: payload,
      headers: { "CONTENT_TYPE" => "application/json" }

    assert_response :bad_request
  end

  test "receive returns 500 when webhook secret is not configured" do
    original_secret = ENV["STRIPE_WEBHOOK_SECRET"]
    ENV.delete("STRIPE_WEBHOOK_SECRET")

    payload = { type: "checkout.session.completed" }.to_json

    post "/stripe/webhooks",
      params: payload,
      headers: {
        "CONTENT_TYPE" => "application/json",
        "HTTP_STRIPE_SIGNATURE" => "t=123,v1=somesignature",
      }

    assert_response :internal_server_error
  ensure
    ENV["STRIPE_WEBHOOK_SECRET"] = original_secret
  end

  test "receive delegates to StripeService.handle_webhook_event" do
    payload = { type: "some.event.type", data: { object: {} } }.to_json
    timestamp = Time.now.to_i
    signature = generate_stripe_signature(payload, timestamp)

    post "/stripe/webhooks",
      params: payload,
      headers: {
        "CONTENT_TYPE" => "application/json",
        "HTTP_STRIPE_SIGNATURE" => "t=#{timestamp},v1=#{signature}",
      }

    # Should succeed even for unknown events (StripeService logs and moves on)
    assert_response :ok
  end

  private

  def generate_stripe_signature(payload, timestamp)
    secret = ENV.fetch("STRIPE_WEBHOOK_SECRET")
    signed_payload = "#{timestamp}.#{payload}"
    OpenSSL::HMAC.hexdigest("SHA256", secret, signed_payload)
  end
end
