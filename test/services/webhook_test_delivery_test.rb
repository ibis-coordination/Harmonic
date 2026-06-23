# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"

class WebhookTestDeliveryTest < ActiveSupport::TestCase
  SECRET = "whsec_test_secret"
  URL = "https://example.com/webhook"

  test "returns ok with status on 2xx response" do
    stub_request(:post, URL).to_return(status: 200, body: '{"received":true}')

    result = WebhookTestDelivery.deliver(url: URL, secret: SECRET)

    assert_equal true, result.ok
    assert_equal 200, result.status
    assert_nil result.error
  end

  test "returns ok=false with status on non-2xx response" do
    stub_request(:post, URL).to_return(status: 502, body: "Bad Gateway")

    result = WebhookTestDelivery.deliver(url: URL, secret: SECRET)

    assert_equal false, result.ok
    assert_equal 502, result.status
    assert_match(/HTTP 502/, result.error.to_s)
  end

  test "returns ok=false with error message on connection refused" do
    stub_request(:post, URL).to_raise(Errno::ECONNREFUSED)

    result = WebhookTestDelivery.deliver(url: URL, secret: SECRET)

    assert_equal false, result.ok
    assert_nil result.status
    assert_match(/Connection refused/i, result.error.to_s)
  end

  test "returns ok=false with error message on timeout" do
    stub_request(:post, URL).to_timeout

    result = WebhookTestDelivery.deliver(url: URL, secret: SECRET)

    assert_equal false, result.ok
    assert_nil result.status
    assert result.error.present?
  end

  test "signs the request with the supplied secret using harmonic.webhook.test event" do
    captured_headers = {}
    captured_body = nil
    stub_request(:post, URL)
      .to_return(status: 200)
      .with do |req|
        captured_headers = req.headers
        captured_body = req.body
        true
      end

    WebhookTestDelivery.deliver(url: URL, secret: SECRET)

    assert_equal "harmonic.webhook.test", captured_headers["X-Harmonic-Event"]
    assert_match(/\Asha256=[0-9a-f]{64}\z/, captured_headers["X-Harmonic-Signature"])
    timestamp = captured_headers["X-Harmonic-Timestamp"]
    expected = WebhookDeliveryService.sign(captured_body, timestamp.to_i, SECRET)
    assert_equal "sha256=#{expected}", captured_headers["X-Harmonic-Signature"]
  end

  test "rejects SSRF-blocked URLs" do
    blocked_url = "http://127.0.0.1/webhook"

    result = WebhookTestDelivery.deliver(url: blocked_url, secret: SECRET)

    assert_equal false, result.ok
    assert result.error.present?
  end
end
