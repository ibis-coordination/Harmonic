# typed: false

class DataExportMailer < ApplicationMailer
  def export_ready(data_export:)
    @data_export = data_export
    @user = data_export.user
    @collective = data_export.collective
    @download_url = "#{@collective.url}/exports/#{data_export.id}"

    mail(
      to: @user.email,
      subject: "Your data export for #{@collective.name} is ready",
    )
  end

  def user_export_ready(data_export:)
    @data_export = data_export
    @user = data_export.user
    @tenant = data_export.tenant
    @download_url = "#{@tenant.url}/settings/data_export/#{data_export.id}"

    mail(
      to: @user.email,
      subject: "Your personal data export is ready",
    )
  end
end
