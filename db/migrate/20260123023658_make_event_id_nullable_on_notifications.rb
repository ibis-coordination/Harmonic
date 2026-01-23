class MakeEventIdNullableOnNotifications < ActiveRecord::Migration[7.0]
  def change
    change_column_null :notifications, :event_id, true
  end
end
