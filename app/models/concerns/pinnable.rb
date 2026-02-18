# typed: false

module Pinnable
  extend ActiveSupport::Concern

  def is_pinned?(tenant:, collective:, user:)
    if tenant.main_collective_id == collective.id
      user.has_pinned?(self)
    else
      collective.has_pinned?(self)
    end
  end

  def pin!(tenant:, collective:, user:)
    if tenant.main_collective_id == collective.id
      user.pin_item!(self)
    else
      collective.pin_item!(self)
    end
  end

  def unpin!(tenant:, collective:, user:)
    if tenant.main_collective_id == collective.id
      user.unpin_item!(self)
    else
      collective.unpin_item!(self)
    end
  end

end
