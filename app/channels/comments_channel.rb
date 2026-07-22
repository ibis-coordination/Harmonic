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
    # Resolve the type via the Commentable registry (a plain lookup, so the
    # untrusted param never reaches a reflection method); only models that
    # include the concern are registered.
    klass = Commentable.model_for(params[:commentable_type])
    id = params[:commentable_id]
    return nil unless klass && id.present?

    # IDs are globally-unique UUIDs, so a bare lookup is unambiguous; the
    # collective membership check is what actually authorizes access.
    klass.find_by(id: id)
  end
end
