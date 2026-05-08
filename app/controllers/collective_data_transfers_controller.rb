# typed: true

class CollectiveDataTransfersController < ApplicationController
  extend T::Sig

  before_action :require_admin

  # GET /collectives/:collective_handle/exports
  sig { void }
  def exports_index
    @exports = DataExport.where(collective_id: @current_collective.id).order(created_at: :desc)
  end

  # POST /collectives/:collective_handle/exports
  sig { void }
  def create_export
    # Rate limit: only 1 active export per collective
    if DataExport.active.exists?(collective_id: @current_collective.id)
      flash[:alert] = "An export is already in progress for this collective."
      return redirect_to collective_exports_path
    end

    data_export = DataExport.create!(
      tenant: @current_tenant,
      collective: @current_collective,
      user: @current_user,
      status: "pending"
    )
    CollectiveExportJob.perform_later(data_export.id)

    flash[:notice] = "Your export is being prepared. This page will update when it's ready."
    redirect_to collective_exports_path
  end

  # GET /collectives/:collective_handle/exports/:id
  sig { void }
  def download_export
    data_export = DataExport.find_by!(id: params[:id], collective_id: @current_collective.id)

    unless data_export.downloadable?
      flash[:alert] = data_export.expired? ? "This export has expired." : "This export is not ready for download."
      return redirect_to collective_exports_path
    end

    redirect_to rails_blob_path(data_export.file, disposition: "attachment"), allow_other_host: true
  end

  # GET /collectives/:collective_handle/imports/new
  sig { void }
  def new_import
    @import = DataImport.new
  end

  # POST /collectives/:collective_handle/imports
  sig { void }
  def create_import
    if params[:file].blank?
      flash[:alert] = "Please select a ZIP file to import."
      return redirect_to new_collective_import_path
    end

    data_import = DataImport.create!(
      tenant: @current_tenant,
      user: @current_user,
      status: "pending"
    )
    data_import.file.attach(params[:file])
    CollectiveImportJob.perform_later(data_import.id)

    flash[:notice] = "Your import is being processed. This page will update when it's complete."
    redirect_to collective_import_path(data_import.id)
  end

  # GET /collectives/:collective_handle/imports/:id
  sig { void }
  def show_import
    @import = DataImport.find_by!(id: params[:id], tenant_id: @current_tenant.id, user_id: @current_user.id)
  end

  private

  sig { void }
  def require_admin
    return if @current_user&.collective_member&.is_admin?

    flash[:alert] = "You must be an admin to access data transfers."
    redirect_to root_path
  end

  sig { returns(String) }
  def collective_path_prefix
    "#{@current_collective.path}"
  end

  sig { returns(String) }
  def collective_exports_path
    "#{collective_path_prefix}/exports"
  end

  sig { returns(String) }
  def new_collective_import_path
    "#{collective_path_prefix}/imports/new"
  end

  sig { params(id: T.untyped).returns(String) }
  def collective_import_path(id)
    "#{collective_path_prefix}/imports/#{id}"
  end
end
