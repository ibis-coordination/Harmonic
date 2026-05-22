# typed: false
require "test_helper"

class TurnstileVerifierTest < ActiveSupport::TestCase
  VERIFY_URL = "https://challenges.cloudflare.com/turnstile/v0/siteverify".freeze

  setup do
    @original_secret = ENV["TURNSTILE_SECRET_KEY"]
  end

  teardown do
    if @original_secret.nil?
      ENV.delete("TURNSTILE_SECRET_KEY")
    else
      ENV["TURNSTILE_SECRET_KEY"] = @original_secret
    end
  end

  test "returns true when TURNSTILE_SECRET_KEY is blank (disabled mode)" do
    ENV.delete("TURNSTILE_SECRET_KEY")
    assert TurnstileVerifier.verify(token: "anything", ip: "1.2.3.4")
  end

  test "returns true when secret is empty string (disabled mode)" do
    ENV["TURNSTILE_SECRET_KEY"] = ""
    assert TurnstileVerifier.verify(token: "anything", ip: "1.2.3.4")
  end

  test "returns false when token is blank (and verifier is enabled)" do
    ENV["TURNSTILE_SECRET_KEY"] = "secret"
    refute TurnstileVerifier.verify(token: nil, ip: "1.2.3.4")
    refute TurnstileVerifier.verify(token: "", ip: "1.2.3.4")
  end

  test "POSTs to siteverify with secret + response + remoteip and returns true on success" do
    ENV["TURNSTILE_SECRET_KEY"] = "the-secret"
    stub_request(:post, VERIFY_URL)
      .with(body: { "secret" => "the-secret", "response" => "tok", "remoteip" => "9.9.9.9" })
      .to_return(status: 200, body: '{"success":true}', headers: { "Content-Type" => "application/json" })

    assert TurnstileVerifier.verify(token: "tok", ip: "9.9.9.9")
  end

  test "returns false when siteverify reports failure" do
    ENV["TURNSTILE_SECRET_KEY"] = "the-secret"
    stub_request(:post, VERIFY_URL)
      .to_return(status: 200, body: '{"success":false,"error-codes":["invalid-input-response"]}',
                 headers: { "Content-Type" => "application/json" })

    refute TurnstileVerifier.verify(token: "tok", ip: "9.9.9.9")
  end

  test "fails closed on network error" do
    ENV["TURNSTILE_SECRET_KEY"] = "the-secret"
    stub_request(:post, VERIFY_URL).to_timeout

    refute TurnstileVerifier.verify(token: "tok", ip: "9.9.9.9")
  end

  test "fails closed on malformed JSON" do
    ENV["TURNSTILE_SECRET_KEY"] = "the-secret"
    stub_request(:post, VERIFY_URL).to_return(status: 200, body: "not json")

    refute TurnstileVerifier.verify(token: "tok", ip: "9.9.9.9")
  end
end
