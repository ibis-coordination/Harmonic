# typed: false

namespace :images do
  desc <<~DESC
    Migrate image-content-type Attachment records on Notes to MediaItem.
      DRY_RUN=1            Count only; no writes.
      BATCH_SIZE           Number of attachments per find_each batch (default 200).
      THROTTLE_EVERY       Sleep after every N migrations (default 50).
      THROTTLE_SECONDS     Seconds to sleep when throttling (default 1.0).
      VALIDATE=1           Re-run MediaItem validations on each migrated row
                           and report any that fail. Default: skip validation.
    The same blob is reattached to the new MediaItem (no file copy);
    the original Attachment row is then destroyed. Idempotent: re-running
    skips Notes that already have a MediaItem pointing at the same blob.

    Variant preprocessing fires automatically via `preprocessed: true` on
    each save, so a large backfill produces a flood of Sidekiq jobs.
    THROTTLE_EVERY/SECONDS exist to space those jobs out so Sidekiq stays
    responsive to user-driven work.
  DESC
  task migrate_note_attachments: :environment do
    dry_run = ENV["DRY_RUN"] == "1"
    batch_size = (ENV["BATCH_SIZE"] || 200).to_i
    throttle_every = (ENV["THROTTLE_EVERY"] || 50).to_i
    throttle_seconds = (ENV["THROTTLE_SECONDS"] || "1.0").to_f
    validate_each = ENV["VALIDATE"] == "1"

    image_attachments = Attachment.unscoped_for_system_job
                                  .where(attachable_type: "Note")
                                  .where("content_type LIKE 'image/%'")
                                  .order(:attachable_id, :id)

    total = image_attachments.count
    puts "Found #{total} image attachments on notes."
    puts "DRY_RUN mode — no writes." if dry_run
    puts "Throttle: sleep #{throttle_seconds}s every #{throttle_every} migrations." if throttle_every.positive?

    migrated = 0
    skipped = 0
    errored = 0
    validation_failures = 0

    image_attachments.find_each(batch_size: batch_size).with_index do |attachment, i|
      note = Note.unscoped_for_system_job.find_by(id: attachment.attachable_id)
      unless note
        errored += 1
        next
      end

      source_blob_id = attachment.file.blob.id
      already_migrated_media_ids = ActiveStorage::Attachment
                                   .where(record_type: "MediaItem", name: "file", blob_id: source_blob_id)
                                   .pluck(:record_id)
      already_migrated = if already_migrated_media_ids.any?
                           MediaItem.unscoped_for_system_job
                                    .where(id: already_migrated_media_ids,
                                           mediable_type: "Note",
                                           mediable_id: note.id)
                                    .exists?
                         else
                           false
                         end
      if already_migrated
        skipped += 1
        next
      end

      if dry_run
        migrated += 1
      else
        next_order = (MediaItem.unscoped_for_system_job
                               .where(mediable_type: "Note", mediable_id: note.id)
                               .maximum(:display_order) || -1) + 1
        new_item = nil
        ActiveRecord::Base.transaction do
          new_item = MediaItem.new(
            tenant_id: attachment.tenant_id,
            collective_id: attachment.collective_id,
            mediable: note,
            content_type: attachment.content_type,
            byte_size: attachment.byte_size,
            display_order: next_order,
            created_by_id: attachment.created_by_id,
            updated_by_id: attachment.updated_by_id,
          )
          # Reattach the same blob — no file copy.
          new_item.file.attach(attachment.file.blob)
          new_item.save!(validate: false)
          attachment.destroy!
        end

        if validate_each && new_item && !new_item.valid?
          validation_failures += 1
          Rails.logger.warn("[images:migrate_note_attachments] post-migration validation failed for MediaItem #{new_item.id}: #{new_item.errors.full_messages.join('; ')}")
        end

        migrated += 1

        if throttle_every.positive? && throttle_seconds.positive? && migrated.positive? && (migrated % throttle_every).zero?
          sleep(throttle_seconds)
        end
      end

      puts "  [#{i + 1}/#{total}] migrated #{attachment.id} → MediaItem" if (i + 1) % 25 == 0
    rescue StandardError => e
      errored += 1
      Rails.logger.error("[images:migrate_note_attachments] #{attachment.id}: #{e.class}: #{e.message}")
    end

    puts "Done. migrated=#{migrated} skipped=#{skipped} errored=#{errored} total=#{total}"
    puts "Validation failures (informational): #{validation_failures}" if validate_each
  end
end
