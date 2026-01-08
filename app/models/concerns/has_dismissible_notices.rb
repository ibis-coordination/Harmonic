# typed: false

module HasDismissibleNotices
  extend ActiveSupport::Concern

  def dismissed_notices
    self.settings['dismissed_notices'] || []
  end

  def dismiss_notice!(notice_id)
    self.settings['dismissed_notices'] ||= []
    self.settings['dismissed_notices'] << notice_id
    save!
  end

end
