# typed: true

class DeletedRecordProxy
  extend T::Sig

  sig { returns(String) }
  def name
    '[deleted]'
  end

  sig { returns(String) }
  def path
    ''
  end

  sig { returns(String) }
  def truncated_id
    '[deleted]'
  end

  sig { returns(DeletedRecordProxy) }
  def superagent
    DeletedRecordProxy.new
  end

  # Backwards compatibility alias
  alias_method :studio, :superagent
end