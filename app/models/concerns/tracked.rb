# typed: false

module Tracked
  extend ActiveSupport::Concern

  included do
    # TODO change to around_ callbacks instead of after_
    # so that tracked changes occur within db transaction.
    after_create :track_creation
    after_update :track_changes
    after_destroy :track_deletion
  end

  def track_creation
    # TODO
    # Webhook.queue_jobs_for(self, { event: "#{self.class.name.underscore}:created", data: self.attributes })
  end

  def track_changes
    # TODO
    # Webhook.queue_jobs_for(self, { event: "#{self.class.name.underscore}:updated", data: saved_changes })
  end

  def track_deletion
    # TODO
    # Webhook.queue_jobs_for(self, { event: "#{self.class.name.underscore}:deleted", data: self.attributes })
  end

  class_methods do
    def is_tracked?
      true
    end
  end
end
