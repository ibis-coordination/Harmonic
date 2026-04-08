# typed: false

require "test_helper"

# These tests guard the rendering boundary for user-uploaded attachments.
#
# IMPORTANT: the actual XSS protection here lives in Rails, not in this app.
# ActiveStorage maintains two configs that together neutralize stored XSS
# from user-uploaded HTML / SVG / XML / etc:
#
#   ActiveStorage.content_types_to_serve_as_binary
#     - Forces Content-Type: application/octet-stream for the listed types,
#       so the browser will not render them as documents.
#
#   ActiveStorage.content_types_allowed_inline
#     - Allowlist of content types that may ever be served with
#       Content-Disposition: inline. Anything not on the list is forced to
#       Content-Disposition: attachment regardless of what the calling
#       controller passes.
#
# Both overrides are baked into the URL ActiveStorage generates (via
# Blob#content_type_for_serving and Blob#forced_disposition_for_serving),
# so they apply equally to local-disk and S3-redirect storage modes.
#
# AttachmentsController#show simply calls rails_blob_path with
# disposition: "inline" and trusts ActiveStorage to override that for
# unsafe types. The tests below verify that trust by following the redirect
# chain all the way to the final blob response and inspecting the actual
# headers the browser will see. If a future Rails version, gem upgrade, or
# config change ever weakens these defaults, these tests will fail and force
# an explicit security review.
class AttachmentsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.set_thread_context(@collective)

    @note = Note.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      updated_by: @user,
      title: "Attachment Host Note",
      text: "Note that hosts attachments for testing"
    )
  end

  def teardown
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
  end

  def create_attachment(content:, filename:, content_type:)
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(content),
      filename: filename,
      content_type: content_type
    )
    Attachment.create!(
      tenant: @tenant,
      collective: @collective,
      attachable: @note,
      file: blob,
      created_by: @user,
      updated_by: @user
    )
  end

  def attachment_path(attachment)
    "/collectives/#{@collective.handle}/n/#{@note.truncated_id}/attachments/#{attachment.id}"
  end

  def fetch_final_response(attachment)
    sign_in_as(@user, tenant: @tenant)
    get attachment_path(attachment)
    follow_redirect! while response.redirect?
    response
  end

  # ============================================
  # Negative cases — script-capable content must NOT render as a document
  # ============================================

  test "html attachment is served as octet-stream + attachment" do
    attachment = create_attachment(
      content: "<html><body><script>alert(document.domain)</script></body></html>",
      filename: "pwn.html",
      content_type: "text/html"
    )

    final = fetch_final_response(attachment)

    # Browser must NOT receive a renderable HTML response.
    assert_no_match %r{^text/html}, final.headers["Content-Type"].to_s,
                    "HTML attachment served with renderable Content-Type: #{final.headers["Content-Type"]}"
    assert_match(/^attachment/, final.headers["Content-Disposition"].to_s,
                 "HTML attachment served with non-attachment disposition: #{final.headers["Content-Disposition"]}")
  end

  test "svg attachment is served as octet-stream + attachment" do
    attachment = create_attachment(
      content: %(<svg xmlns="http://www.w3.org/2000/svg" onload="alert(document.domain)"/>),
      filename: "pwn.svg",
      content_type: "image/svg+xml"
    )

    final = fetch_final_response(attachment)

    assert_no_match %r{^image/svg}, final.headers["Content-Type"].to_s,
                    "SVG attachment served with renderable Content-Type: #{final.headers["Content-Type"]}"
    assert_match(/^attachment/, final.headers["Content-Disposition"].to_s,
                 "SVG attachment served with non-attachment disposition: #{final.headers["Content-Disposition"]}")
  end

  # ============================================
  # Positive cases — safe types should still render inline so previews work
  # ============================================

  # Minimal valid PNG: 1x1 transparent pixel.
  def valid_png_bytes
    [
      "\x89PNG\r\n\x1a\n",
      "\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89",
      "\x00\x00\x00\nIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\r\n-\xb4",
      "\x00\x00\x00\x00IEND\xaeB`\x82",
    ].join.b
  end

  test "png attachment is served inline with image content type" do
    attachment = create_attachment(
      content: valid_png_bytes,
      filename: "pixel.png",
      content_type: "image/png"
    )

    final = fetch_final_response(attachment)

    assert_match %r{^image/png}, final.headers["Content-Type"].to_s,
                 "PNG attachment should be served as image/png, got: #{final.headers["Content-Type"]}"
    assert_match(/^inline/, final.headers["Content-Disposition"].to_s,
                 "PNG attachment should be served inline, got: #{final.headers["Content-Disposition"]}")
  end

  test "pdf attachment is served inline with pdf content type" do
    pdf_bytes = "%PDF-1.4\n1 0 obj\n<<>>\nendobj\ntrailer\n<<>>\n%%EOF\n".b
    attachment = create_attachment(
      content: pdf_bytes,
      filename: "doc.pdf",
      content_type: "application/pdf"
    )

    final = fetch_final_response(attachment)

    assert_match %r{^application/pdf}, final.headers["Content-Type"].to_s,
                 "PDF attachment should be served as application/pdf, got: #{final.headers["Content-Type"]}"
    assert_match(/^inline/, final.headers["Content-Disposition"].to_s,
                 "PDF attachment should be served inline, got: #{final.headers["Content-Disposition"]}")
  end
end
