# typed: false

# Our replacement for ActiveStorage::DirectUploadsController. The default
# upstream controller inherits ActiveStorage::BaseController, which skips
# all of our app-level auth gates (login required, session timeout,
# suspension, activation gate, tenant billing, collective archived
# check, etc.). Routing the endpoint through this controller — which
# inherits ApplicationController — means every present and future auth
# check applies automatically.
#
# The action itself mirrors what ActiveStorage::DirectUploadsController#create
# does: create a Blob row before the actual upload happens, return the
# signed_id plus the direct-upload URL the JS client will PUT to. The
# extras over upstream:
#
#  - byte_size cap enforced before reserving a blob slot
#  - everything else (auth, tenant scoping, csrf) is inherited
class DirectUploadsController < ApplicationController
  # ActiveStorage's URL helpers need to know the request host/protocol when
  # generating the direct-upload URL the client will PUT to. The upstream
  # controller gets this for free via its parent ActiveStorage::BaseController;
  # we replicate that here so url generation works.
  include ActiveStorage::SetCurrent

  # Aligns with MediaItem::MAX_FILE_BYTES (15 MB) plus generous headroom
  # for any future non-MediaItem direct upload (e.g. data exports).
  MAX_DIRECT_UPLOAD_BYTES = 25 * 1024 * 1024 # 25 MB

  before_action :enforce_max_byte_size

  def create
    blob = ActiveStorage::Blob.create_before_direct_upload!(**blob_args)
    render json: direct_upload_json(blob)
  end

  private

  def blob_args
    params.require(:blob).permit(:filename, :byte_size, :checksum, :content_type, metadata: {}).to_h.symbolize_keys
  end

  def direct_upload_json(blob)
    blob.as_json(root: false, methods: :signed_id).merge(direct_upload: {
      url: blob.service_url_for_direct_upload,
      headers: blob.service_headers_for_direct_upload,
    })
  end

  def enforce_max_byte_size
    claimed = params.dig(:blob, :byte_size).to_i
    return if claimed > 0 && claimed <= MAX_DIRECT_UPLOAD_BYTES

    render json: { error: "File too large" }, status: :content_too_large
  end
end
