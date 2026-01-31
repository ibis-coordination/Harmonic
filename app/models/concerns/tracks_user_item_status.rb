# typed: false

# Include this concern in models that need to track user status for items.
# When records are created or updated, UserItemStatus records are created/updated
# to track user interactions like reading, voting, participating, and creating.
#
# Models should define `user_item_status_updates` to return an array of hashes
# specifying what to update. Each hash should contain:
#   - tenant_id: (required)
#   - user_id: (required)
#   - item_type: (required) "Note", "Decision", or "Commitment"
#   - item_id: (required)
#   - And one or more status flags:
#     - is_creator: true
#     - has_read: true, read_at: Time
#     - has_voted: true, voted_at: Time
#     - is_participating: true, participated_at: Time
#
# Return an empty array to skip tracking.
#
module TracksUserItemStatus
  extend ActiveSupport::Concern

  included do
    after_commit :update_user_item_status_records, on: [:create, :update]
  end

  private

  def update_user_item_status_records
    updates = user_item_status_updates
    return if updates.blank?

    updates.each do |update|
      next if update[:tenant_id].blank? || update[:user_id].blank?
      next if update[:item_type].blank? || update[:item_id].blank?

      UserItemStatus.upsert(
        {
          id: SecureRandom.uuid,
          tenant_id: update[:tenant_id],
          user_id: update[:user_id],
          item_type: update[:item_type],
          item_id: update[:item_id],
          is_creator: update[:is_creator] || false,
          has_read: update[:has_read] || false,
          read_at: update[:read_at],
          has_voted: update[:has_voted] || false,
          voted_at: update[:voted_at],
          is_participating: update[:is_participating] || false,
          participated_at: update[:participated_at],
        },
        unique_by: [:tenant_id, :user_id, :item_type, :item_id]
      )
    end
  end

  # Override this method in the including class to return status updates.
  # Should return an array of hashes or an empty array.
  def user_item_status_updates
    []
  end
end
