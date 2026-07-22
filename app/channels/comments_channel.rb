# typed: false

# Live comment updates for a single resource. Clients subscribe with the root
# resource's type and id; the server streams for that resource and `Note`
# broadcasts to it whenever a comment on it changes.
#
# Read access is gated the same way the web request is: by collective
# membership. `Collective#accessible_by?` is the shared predicate
# ApplicationController uses to authorize collective access, so a subscriber
# can only ever receive a resource they could already read.
class CommentsChannel < ApplicationCable::Channel
  def subscribed
    stream_for_authorized(find_resource) { |resource| collective_accessible?(resource) }
  end

  private

  def find_resource
    klass = commentable_class
    return nil unless klass

    # IDs are globally-unique UUIDs, so a bare lookup is unambiguous; the
    # collective membership check is what actually authorizes access.
    klass.find_by(id: params[:commentable_id])
  end

  # Resolve the subscription's commentable_type to a model, allowing only
  # models that opt into comments via the Commentable concern — the same
  # source of truth `is_commentable?` reflects.
  def commentable_class
    klass = params[:commentable_type].to_s.safe_constantize
    return nil unless klass.is_a?(Class) && klass < ApplicationRecord && klass.include?(Commentable)

    klass
  end
end
