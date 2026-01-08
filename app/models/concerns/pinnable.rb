# typed: false

module Pinnable
  extend ActiveSupport::Concern

  def is_pinned?(tenant:, studio:, user:)
    if tenant.main_studio_id == studio.id
      user.has_pinned?(self)
    else
      studio.has_pinned?(self)
    end
  end

  def pin!(tenant:, studio:, user:)
    if tenant.main_studio_id == studio.id
      user.pin_item!(self)
    else
      studio.pin_item!(self)
    end
  end

  def unpin!(tenant:, studio:, user:)
    if tenant.main_studio_id == studio.id
      user.unpin_item!(self)
    else
      studio.unpin_item!(self)
    end
  end

end
