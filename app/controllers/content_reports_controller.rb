# typed: false

class ContentReportsController < ApplicationController
  before_action :require_user

  def new
    @reportable_type = params[:reportable_type]
    @reportable_id = params[:reportable_id]
    @page_title = "Report Content"

    respond_to do |format|
      format.html
      format.md
    end
  end

  def create
    reportable = find_reportable(params[:reportable_type], params[:reportable_id])

    if reportable.nil?
      flash[:alert] = "Content not found."
      redirect_back fallback_location: "/"
      return
    end

    report = ContentReport.new(
      reporter: current_user,
      reportable: reportable,
      reason: params[:reason],
      description: params[:description],
    )

    if report.save
      flash[:notice] = "Thank you for reporting. Our team will review this."
      redirect_back fallback_location: "/"
    else
      flash[:alert] = report.errors.full_messages.join(", ")
      redirect_back fallback_location: "/content-reports/new?reportable_type=#{params[:reportable_type]}&reportable_id=#{params[:reportable_id]}"
    end
  end

  private

  def find_reportable(type, id)
    # Use tenant_scoped_only to find content across all collectives within the tenant
    case type
    when "Note" then Note.tenant_scoped_only.find_by(id: id)
    when "Decision" then Decision.tenant_scoped_only.find_by(id: id)
    when "Commitment" then Commitment.tenant_scoped_only.find_by(id: id)
    end
  end

  def require_user
    return if current_user

    respond_to do |format|
      format.html { redirect_to "/login" }
      format.md { render plain: "# Error\n\nYou must be logged in.", status: :unauthorized }
    end
  end
end
