# Updates Active Storage attachment records from 'Studio' to 'Superagent'.
#
# The RenameStudioToSuperagent migration renamed the table and columns,
# but didn't update the polymorphic record_type in active_storage_attachments.
# This caused all studio icon images to disappear after deployment.
#
class FixActiveStorageRecordTypeForSuperagent < ActiveRecord::Migration[7.0]
  def up
    execute <<-SQL
      UPDATE active_storage_attachments
      SET record_type = 'Superagent'
      WHERE record_type = 'Studio'
    SQL
  end

  def down
    execute <<-SQL
      UPDATE active_storage_attachments
      SET record_type = 'Studio'
      WHERE record_type = 'Superagent'
    SQL
  end
end
