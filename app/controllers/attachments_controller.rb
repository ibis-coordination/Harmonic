# typed: false

class AttachmentsController < ApplicationController
  def show
    attachment = current_resource.attachments.find_by(id: params[:attachment_id])
    return render status: 404, plain: 'Attachment Not Found' unless attachment
    file = attachment.file
    redirect_to rails_blob_path(file, disposition: "inline")
  end

  private

  def current_resource_model
    if params[:note_id]
      Note
    elsif params[:decision_id]
      Decision
    elsif params[:commitment_id]
      Commitment
    end
  end
end