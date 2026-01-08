# typed: false

module CanPin
  extend ActiveSupport::Concern

  def pin_item!(item)
    pin_items!([item])
  end

  def pin_items!(items)
    migrate_pinned_array_to_hash
    items.each do |item|
      self.settings['pinned'][item.id] ||= {
        type: item.class.to_s,
        id: item.id,
        pinned_at: Time.now
      }
    end
    save!
  end

  def migrate_pinned_array_to_hash
    if self.settings['pinned'].is_a?(Array)
      previous_pinned = self.settings['pinned']
      self.settings['pinned'] = {}
      previous_pinned.each do |item|
        self.settings['pinned'][item['id']] ||= item
      end
    end
  end

  def unpin_item!(item)
    migrate_pinned_array_to_hash
    self.settings['pinned'].delete(item.id)
    save!
  end

  def pinned_items
    migrate_pinned_array_to_hash
    settings['pinned'].map do |id, item|
      resource = item['type'].constantize.find_by(id: id)
      resource ? {
        item: resource,
        pinned_at: item['pinned_at'] || Time.at(0)
      } : nil
    end.compact.sort_by {|p| p[:pinned_at] }.reverse
  end

  def has_pinned?(item)
    migrate_pinned_array_to_hash
    !!settings['pinned'][item.id]
  end

end
