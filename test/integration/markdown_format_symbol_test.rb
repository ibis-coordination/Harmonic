require "test_helper"

# Pins the Mime::Type symbol used by `text/markdown` requests. The 6-condition
# anonymous-read bypass in ApplicationController#validate_unauthenticated_access
# explicitly checks `request.format.symbol == :md`. If a Rails upgrade ever
# changed this to e.g. `:markdown`, the bypass would silently stop allowing
# markdown responses for anon — failing closed (302 to login), but breaking the
# documented dual-interface contract.
class MarkdownFormatSymbolTest < ActionDispatch::IntegrationTest
  test "Accept: text/markdown resolves to request.format.symbol == :md" do
    req = ActionDispatch::Request.new(
      "HTTP_ACCEPT" => "text/markdown",
      "REQUEST_METHOD" => "GET",
      "PATH_INFO" => "/"
    )
    assert_equal :md, req.format.symbol
  end

  test ":md mime type is registered as text/markdown" do
    assert_equal "text/markdown", Mime::Type.lookup_by_extension(:md).to_s
  end
end
