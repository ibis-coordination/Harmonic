# typed: false

require "test_helper"

class CaddyfileGeneratorTest < ActiveSupport::TestCase
  test "emits an llm edge block that forwards only /v1/* to the gateway" do
    output = CaddyfileGenerator.new.generate
    hostname = ENV.fetch("HOSTNAME")

    block = output[/^llm\.#{Regexp.escape(hostname)} \{.*?^\}/m]
    assert block, "expected an llm.#{hostname} block in the generated Caddyfile"
    assert_includes block, "handle /v1/* {"
    assert_includes block, "reverse_proxy llm-gateway:4500"
    assert_includes block, "respond 403"
    # The internal relay path must not be routed from the edge.
    assert_not_includes block, "reverse_proxy web:3000"
  end

  test "tenant subdomain blocks still proxy to web and block /internal" do
    output = CaddyfileGenerator.new.generate
    hostname = ENV.fetch("HOSTNAME")
    primary = ENV.fetch("PRIMARY_SUBDOMAIN")

    block = output[/^#{Regexp.escape(primary)}\.#{Regexp.escape(hostname)} \{.*?^\}/m]
    assert block
    assert_includes block, "reverse_proxy web:3000"
    assert_includes block, "handle /internal/* {"
  end

  # A client-sent Client-IP that disagrees with the X-Forwarded-For Caddy
  # sets makes ActionDispatch::RemoteIp raise IpSpoofAttackError (a 500).
  # Clients never have a reason to send it, so the proxy drops it.
  test "the web proxy strips the Client-IP request header" do
    output = CaddyfileGenerator.new.generate
    hostname = ENV.fetch("HOSTNAME")
    primary = ENV.fetch("PRIMARY_SUBDOMAIN")

    block = output[/^#{Regexp.escape(primary)}\.#{Regexp.escape(hostname)} \{.*?^\}/m]
    assert_match(/reverse_proxy web:3000 \{\n\t\theader_up -Client-IP\n\t\}/, block)
  end
end
