# typed: false

# Endpoints for attaching, removing, reordering, and captioning images on a
# Note. Direct uploads flow through Rails' built-in
# /rails/active_storage/direct_uploads — the browser posts a signed_id from
# that endpoint to #create here, and we materialize a MediaItem pointing at
# the blob.
class MediaItemsController < ApplicationController
  before_action :load_note
  before_action :ensure_editor

  def create
    if @note.collective.file_storage_usage >= @note.collective.file_storage_limit
      return render(
        json: { error: "Collective storage limit reached." },
        status: :unprocessable_entity
      )
    end

    item = MediaItem.new(
      tenant: @note.tenant,
      collective: @note.collective,
      mediable: @note,
      created_by: @current_user,
      updated_by: @current_user,
      alt_text: params[:alt_text].presence,
      caption: params[:caption].presence,
      display_order: next_display_order,
    )

    begin
      item.file.attach(params.require(:signed_id))
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      return render json: { errors: ["invalid signed_id"] }, status: :unprocessable_entity
    end

    if item.save
      render json: serialize_item(item), status: :created
    else
      render json: { errors: item.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    item = @note.media_items.find_by(id: params[:id])
    return render(json: { error: "Not found" }, status: :not_found) unless item

    allowed = params.permit(:alt_text, :caption).to_h
    if item.update(allowed.merge(updated_by: @current_user))
      render json: serialize_item(item)
    else
      render json: { errors: item.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    item = @note.media_items.find_by(id: params[:id])
    return render(json: { error: "Not found" }, status: :not_found) unless item

    item.destroy!
    render json: { ok: true }
  end

  # Bulk reorder. Expects params[:order] as an array of media_item IDs in
  # the new display order. Items not belonging to this note are ignored
  # silently — clients shouldn't be able to grab cross-note IDs anyway, but
  # this is a defense-in-depth check.
  def reorder
    ids = Array(params[:order]).map(&:to_s)
    items_by_id = @note.media_items.index_by { |i| i.id.to_s }

    MediaItem.transaction do
      ids.each_with_index do |id, index|
        item = items_by_id[id]
        next unless item

        item.update_columns(display_order: index, updated_by_id: @current_user.id, updated_at: Time.current)
      end
    end

    render json: { ok: true, order: ids & items_by_id.keys }
  end

  private

  def load_note
    @note = current_note
    render(json: { error: "Note not found" }, status: :not_found) unless @note
  end

  def ensure_editor
    return if @note.user_can_edit?(@current_user)

    render json: { error: "Forbidden" }, status: :forbidden
  end

  def next_display_order
    (@note.media_items.maximum(:display_order) || -1) + 1
  end

  def serialize_item(item)
    {
      id: item.id,
      alt_text: item.alt_text,
      caption: item.caption,
      display_order: item.display_order,
      thumbnail_url: item.url(variant: :thumbnail),
      medium_url: item.url(variant: :medium),
      large_url: item.url(variant: :large),
      content_type: item.content_type,
      byte_size: item.byte_size,
    }
  end
end
