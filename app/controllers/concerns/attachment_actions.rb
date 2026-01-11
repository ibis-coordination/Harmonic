# typed: false

module AttachmentActions
  extend ActiveSupport::Concern

  # Maximum base64 encoded payload size (15MB to account for ~33% base64 overhead on 10MB file)
  MAX_BASE64_PAYLOAD_SIZE = 15.megabytes

  def describe_add_attachment
    resource = current_resource
    return render status: :not_found, plain: "404 Not Found" unless resource
    return render status: :forbidden, plain: "403 Forbidden - Edit permission required" unless can_edit_resource?(resource)
    return render status: :forbidden, plain: "403 Forbidden - File uploads are not enabled" unless file_uploads_allowed?

    render_action_description({
                                action_name: "add_attachment",
                                resource: resource,
                                description: "Add a file attachment to this #{current_resource_model.name.downcase}",
                                params: [
                                  {
                                    name: "file",
                                    description: "The file to attach (base64 encoded data with content_type and filename)",
                                    type: "object",
                                  },
                                ],
                              })
  end

  def add_attachment
    resource = current_resource
    return render status: :not_found, plain: "404 Not Found" unless resource
    return render status: :forbidden, plain: "403 Forbidden - Edit permission required" unless can_edit_resource?(resource)
    return render status: :forbidden, plain: "403 Forbidden - File uploads are not enabled" unless file_uploads_allowed?

    file_param = params[:file]
    unless file_param.present?
      return render_action_error({
                                   action_name: "add_attachment",
                                   resource: resource,
                                   error: "file parameter is required",
                                 })
    end

    begin
      # Handle both uploaded files and base64 encoded data
      if file_param.respond_to?(:content_type)
        # Direct file upload
        attachment = Attachment.create!(
          tenant_id: resource.tenant_id,
          studio_id: resource.studio_id,
          attachable: resource,
          file: file_param,
          created_by: @current_user,
          updated_by: @current_user
        )
      elsif file_param.is_a?(Hash) || file_param.is_a?(ActionController::Parameters)
        # Base64 encoded file
        data = file_param[:data] || file_param["data"]
        content_type = file_param[:content_type] || file_param["content_type"]
        filename = file_param[:filename] || file_param["filename"]

        unless data.present? && content_type.present? && filename.present?
          return render_action_error({
                                       action_name: "add_attachment",
                                       resource: resource,
                                       error: "file must include data, content_type, and filename",
                                     })
        end

        # Check base64 payload size before decoding to prevent memory issues
        if data.bytesize > MAX_BASE64_PAYLOAD_SIZE
          return render_action_error({
                                       action_name: "add_attachment",
                                       resource: resource,
                                       error: "file data exceeds maximum size of #{MAX_BASE64_PAYLOAD_SIZE / 1.megabyte}MB encoded",
                                     })
        end

        decoded_data = Base64.decode64(data)
        io = StringIO.new(decoded_data)
        blob = ActiveStorage::Blob.create_and_upload!(
          io: io,
          filename: filename,
          content_type: content_type
        )

        attachment = Attachment.create!(
          tenant_id: resource.tenant_id,
          studio_id: resource.studio_id,
          attachable: resource,
          file: blob,
          created_by: @current_user,
          updated_by: @current_user
        )
      else
        return render_action_error({
                                     action_name: "add_attachment",
                                     resource: resource,
                                     error: "Invalid file format",
                                   })
      end

      render_action_success({
                              action_name: "add_attachment",
                              resource: resource,
                              result: "Attachment '#{attachment.filename}' added successfully.",
                            })
    rescue ActiveRecord::RecordInvalid => e
      render_action_error({
                            action_name: "add_attachment",
                            resource: resource,
                            error: e.message,
                          })
    end
  end

  def actions_index_attachment
    resource = current_resource
    return render status: :not_found, plain: "404 Not Found" unless resource
    return render status: :forbidden, plain: "403 Forbidden - Edit permission required" unless can_edit_resource?(resource)

    attachment = resource.attachments.find_by(id: params[:attachment_id])
    return render status: :not_found, plain: "404 Attachment not found" unless attachment

    @page_title = "Actions | Attachment"
    render_actions_index({
                           actions: [
                             {
                               name: "remove_attachment",
                               params_string: "()",
                               description: "Remove this attachment",
                             },
                           ],
                         })
  end

  def describe_remove_attachment
    resource = current_resource
    return render status: :not_found, plain: "404 Not Found" unless resource
    return render status: :forbidden, plain: "403 Forbidden - Edit permission required" unless can_edit_resource?(resource)

    attachment = resource.attachments.find_by(id: params[:attachment_id])
    return render status: :not_found, plain: "404 Attachment not found" unless attachment

    render_action_description({
                                action_name: "remove_attachment",
                                resource: resource,
                                description: "Remove attachment '#{attachment.filename}' from this #{current_resource_model.name.downcase}",
                                params: [],
                              })
  end

  def remove_attachment
    resource = current_resource
    return render status: :not_found, plain: "404 Not Found" unless resource
    return render status: :forbidden, plain: "403 Forbidden - Edit permission required" unless can_edit_resource?(resource)

    attachment = resource.attachments.find_by(id: params[:attachment_id])
    return render status: :not_found, plain: "404 Attachment not found" unless attachment

    filename = attachment.filename
    attachment.destroy!

    render_action_success({
                            action_name: "remove_attachment",
                            resource: resource,
                            result: "Attachment '#{filename}' removed successfully.",
                          })
  end

  private

  # Check if user can edit the resource
  # Notes use user_can_edit?, Decisions/Commitments use can_edit_settings?
  def can_edit_resource?(resource)
    return false unless @current_user

    if resource.respond_to?(:user_can_edit?)
      resource.user_can_edit?(@current_user)
    elsif resource.respond_to?(:can_edit_settings?)
      resource.can_edit_settings?(@current_user)
    else
      false
    end
  end

  # Check if file uploads are enabled for both tenant and studio
  def file_uploads_allowed?
    @current_tenant&.allow_file_uploads? && @current_studio&.allow_file_uploads?
  end
end
