# typed: false

module HasTruncatedId
  extend ActiveSupport::Concern

  def truncated_id
    super || id.to_s[0..7]
  end

  class_methods do
    def has_truncated_id?
      true
    end

    def find(id_or_truncated_id)
      if id_or_truncated_id.to_s.length == 8
        find_by!(truncated_id: id_or_truncated_id)
      else
        return super(id_or_truncated_id)
      end
    end
  end

end
