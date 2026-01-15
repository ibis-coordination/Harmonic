# typed: false

module Pinnable
  extend ActiveSupport::Concern

  def is_pinned?(tenant:, superagent:, user:)
    if tenant.main_superagent_id == superagent.id
      user.has_pinned?(self)
    else
      superagent.has_pinned?(self)
    end
  end

  def pin!(tenant:, superagent:, user:)
    if tenant.main_superagent_id == superagent.id
      user.pin_item!(self)
    else
      superagent.pin_item!(self)
    end
  end

  def unpin!(tenant:, superagent:, user:)
    if tenant.main_superagent_id == superagent.id
      user.unpin_item!(self)
    else
      superagent.unpin_item!(self)
    end
  end

end
