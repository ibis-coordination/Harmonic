# typed: true

# Renders the per-agent body of the `harmonic://context` MCP resource.
# Personalized to the connected agent: identity summary, principal,
# identity prompt excerpt, and the agent's collective memberships, plus
# a pointer to the getting-started doc.
#
# The document body lives in `app/views/mcp/context.md.erb`.
module Mcp
  class ContextResource
    extend T::Sig

    sig { params(user: User).returns(String) }
    def self.render(user)
      ApplicationController.render(
        template: "mcp/context",
        formats: [:md],
        layout: false,
        assigns: { user: user },
      )
    end
  end
end
