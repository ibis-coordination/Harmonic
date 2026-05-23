# typed: false

# TODO(media-items-phase-2): DELETE THIS FILE BEFORE MERGING TO MAIN.
#
# These tests cover `rake images:migrate_note_attachments`, a one-shot
# data migration that runs once in production after this PR ships. The
# tests exist to prove on the PR branch's CI run that the rake task
# works end-to-end. Once that CI run is green, the tests have served
# their purpose: there's no recurring regression they guard against
# (Rails framework + model behavior is covered by the model/controller
# tests in this PR), and carrying them on main means ~15s of CI per PR
# forever plus mental overhead for future readers wondering "is this
# migration still active?".
#
# The rake task itself (`lib/tasks/images.rake`) STAYS on main until
# it's been run in prod; it'll be deleted in a follow-up PR after
# confirming `Attachment.where(attachable_type: 'Note').where("content_type LIKE 'image/%'").count == 0`.

require "test_helper"
require "rake"

class MigrateNoteAttachmentsTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("images:migrate_note_attachments")
    Rake::Task["images:migrate_note_attachments"].reenable

    @tenant = Tenant.create!(subdomain: "migr-#{SecureRandom.hex(4)}", name: "Migration Test")
    @user = User.create!(email: "#{SecureRandom.hex(8)}@example.com", name: "Migrate User", user_type: "human")
    @collective = Collective.create!(tenant: @tenant, created_by: @user, name: "Migr Collective",
                                     handle: "migr-#{SecureRandom.hex(4)}")
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.set_thread_context(@collective)
    @note = Note.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      updated_by: @user,
      title: "Note with mixed attachments",
      text: "body"
    )
  end

  teardown do
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
  end

  def valid_png_bytes
    "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\r\n-\xb4\x00\x00\x00\x00IEND\xaeB`\x82".b
  end

  def create_attachment(content_type:, filename:, content:)
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

  test "migrates image attachments to MediaItem, keeps PDFs as Attachment, preserves blobs" do
    img1 = create_attachment(content_type: "image/png", filename: "a.png", content: valid_png_bytes)
    img2 = create_attachment(content_type: "image/png", filename: "b.png", content: valid_png_bytes)
    pdf = create_attachment(content_type: "application/pdf", filename: "a.pdf",
                            content: "%PDF-1.4\n1 0 obj\n<<>>\nendobj\ntrailer\n<<>>\n%%EOF\n")

    img1_blob_id = img1.file.blob.id
    img2_blob_id = img2.file.blob.id
    pdf_blob_id = pdf.file.blob.id

    Tenant.clear_thread_scope
    Collective.clear_thread_scope
    Rake::Task["images:migrate_note_attachments"].invoke
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.set_thread_context(@collective)

    @note.reload
    assert_equal 2, @note.media_items.count, "expected 2 MediaItems"
    assert_equal 1, @note.attachments.count, "expected 1 Attachment (PDF) remaining"

    media_blob_ids = @note.media_items.map { |m| m.file.blob.id }
    assert_includes media_blob_ids, img1_blob_id, "image1 blob should be reused"
    assert_includes media_blob_ids, img2_blob_id, "image2 blob should be reused"
    assert_equal pdf_blob_id, @note.attachments.first.file.blob.id, "PDF blob should be untouched"

    orders = @note.media_items.map(&:display_order).sort
    assert_equal [0, 1], orders, "display_order should be assigned in sequence"
  end

  test "is idempotent — re-running migrates nothing" do
    create_attachment(content_type: "image/png", filename: "a.png", content: valid_png_bytes)
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
    Rake::Task["images:migrate_note_attachments"].invoke
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.set_thread_context(@collective)
    Rake::Task["images:migrate_note_attachments"].reenable

    pre_count = MediaItem.where(mediable: @note).count
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
    Rake::Task["images:migrate_note_attachments"].invoke
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.set_thread_context(@collective)
    assert_equal pre_count, MediaItem.where(mediable: @note).count
  end

  test "DRY_RUN does not modify the database" do
    create_attachment(content_type: "image/png", filename: "a.png", content: valid_png_bytes)
    ENV["DRY_RUN"] = "1"
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
    Rake::Task["images:migrate_note_attachments"].invoke
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.set_thread_context(@collective)

    assert_equal 0, MediaItem.where(mediable: @note).count
    assert_equal 1, @note.attachments.count
  ensure
    ENV.delete("DRY_RUN")
  end
end
