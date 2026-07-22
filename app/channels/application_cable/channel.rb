# typed: false

module ApplicationCable
  class Channel < ActionCable::Channel::Base
    private

    # Shared subscription plumbing: stream `resource`'s messages only if the
    # block authorizes it, otherwise reject. Every channel authorizes a
    # different resource by a different rule, but the resolve → authorize →
    # stream (or reject) shape is the same — this is where it lives once.
    def stream_for_authorized(resource)
      return reject unless resource && yield(resource)

      stream_for resource
    end

    # The shared read gate: access to the resource's collective. This is the
    # same predicate ApplicationController uses to authorize a web request
    # (`current_collective.accessible_by?`), so a subscriber can only ever
    # receive a resource whose collective they could already read.
    def collective_accessible?(resource)
      collective = resource.try(:collective)
      collective.present? && collective.accessible_by?(current_user)
    end
  end
end
