# typed: false

class DeletedRecordProxy
  def name
    '[deleted]'
  end

  def path
    ''
  end

  def truncated_id
    '[deleted]'
  end

  def studio
    DeletedRecordProxy.new
  end
end