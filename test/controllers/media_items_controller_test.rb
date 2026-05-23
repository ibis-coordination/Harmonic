# typed: false

require "test_helper"

class MediaItemsControllerTest < ActionDispatch::IntegrationTest
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
      title: "Media Host Note",
      text: "Note that hosts images for testing"
    )
  end

  def teardown
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
  end

  def valid_png_bytes
    "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\r\n-\xb4\x00\x00\x00\x00IEND\xaeB`\x82".b
  end

  def create_blob(content: valid_png_bytes, filename: "a.png", content_type: "image/png")
    ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(content),
      filename: filename,
      content_type: content_type
    )
  end

  def note_path
    "/collectives/#{@collective.handle}/n/#{@note.truncated_id}"
  end

  test "create attaches a MediaItem to the note" do
    sign_in_as(@user, tenant: @tenant)
    blob = create_blob

    assert_difference -> { @note.media_items.count }, 1 do
      post "#{note_path}/media_items", params: { signed_id: blob.signed_id, alt_text: "A pixel" }
    end

    assert_response :created
    item = @note.media_items.last
    body = JSON.parse(response.body)
    assert_equal item.id, body["id"]
    assert_equal "A pixel", body["alt_text"]
    assert_includes body.keys, "thumbnail_url"
    assert_includes body.keys, "medium_url"
    assert_includes body.keys, "large_url"
  end

  test "create assigns next display_order" do
    sign_in_as(@user, tenant: @tenant)
    blob1 = create_blob(filename: "1.png")
    blob2 = create_blob(filename: "2.png")
    blob3 = create_blob(filename: "3.png")

    post "#{note_path}/media_items", params: { signed_id: blob1.signed_id }
    assert_response :created
    post "#{note_path}/media_items", params: { signed_id: blob2.signed_id }
    assert_response :created
    post "#{note_path}/media_items", params: { signed_id: blob3.signed_id }
    assert_response :created

    orders = @note.media_items.reload.map(&:display_order)
    assert_equal [0, 1, 2], orders
  end

  test "create rejects non-image blobs" do
    sign_in_as(@user, tenant: @tenant)
    blob = create_blob(content: "%PDF-1.4\n", filename: "doc.pdf", content_type: "application/pdf")

    post "#{note_path}/media_items", params: { signed_id: blob.signed_id }
    assert_response :unprocessable_entity
    assert_equal 0, @note.media_items.count
  end

  test "create denies non-editor users" do
    other_user = create_user(name: "Outsider", email: "outsider_#{SecureRandom.hex(4)}@example.com")
    @collective.add_user!(other_user)
    sign_in_as(other_user, tenant: @tenant)
    blob = create_blob

    post "#{note_path}/media_items", params: { signed_id: blob.signed_id }
    assert_response :forbidden
    assert_equal 0, @note.media_items.count
  end

  test "create rejects when unauthenticated" do
    blob = create_blob
    post "#{note_path}/media_items", params: { signed_id: blob.signed_id }
    # Unauthenticated requests in this app land on login flows; the controller
    # at minimum must not create a record. We assert that and accept any
    # auth-gating response.
    assert_equal 0, @note.media_items.count
    assert_not response.successful?
  end

  test "update updates alt_text" do
    sign_in_as(@user, tenant: @tenant)
    item = MediaItem.create!(
      tenant: @tenant,
      collective: @collective,
      mediable: @note,
      created_by: @user,
      updated_by: @user,
      file: create_blob
    )

    patch "#{note_path}/media_items/#{item.id}", params: { alt_text: "Updated description" }
    assert_response :ok
    assert_equal "Updated description", item.reload.alt_text
  end

  test "destroy removes a MediaItem" do
    sign_in_as(@user, tenant: @tenant)
    item = MediaItem.create!(
      tenant: @tenant,
      collective: @collective,
      mediable: @note,
      created_by: @user,
      updated_by: @user,
      file: create_blob
    )

    delete "#{note_path}/media_items/#{item.id}"
    assert_response :ok
    assert_not MediaItem.exists?(item.id)
  end

  test "reorder updates display_order from supplied list" do
    sign_in_as(@user, tenant: @tenant)
    a = MediaItem.create!(tenant: @tenant, collective: @collective, mediable: @note,
                          created_by: @user, updated_by: @user, file: create_blob(filename: "a.png"),
                          display_order: 0)
    b = MediaItem.create!(tenant: @tenant, collective: @collective, mediable: @note,
                          created_by: @user, updated_by: @user, file: create_blob(filename: "b.png"),
                          display_order: 1)
    c = MediaItem.create!(tenant: @tenant, collective: @collective, mediable: @note,
                          created_by: @user, updated_by: @user, file: create_blob(filename: "c.png"),
                          display_order: 2)

    patch "#{note_path}/media_items/reorder", params: { order: [c.id, a.id, b.id] }
    assert_response :ok
    assert_equal [c.id, a.id, b.id], @note.media_items.reload.map(&:id)
  end
end
