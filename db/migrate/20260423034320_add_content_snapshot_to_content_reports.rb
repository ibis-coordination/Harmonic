class AddContentSnapshotToContentReports < ActiveRecord::Migration[7.2]
  def change
    add_column :content_reports, :content_snapshot, :text
  end
end
