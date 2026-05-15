# typed: strict
# frozen_string_literal: true

# Identity prompt for the Trio in-app assistant. The prompt text lives in
# system_prompt.md alongside this file so it can be iterated on with normal
# Markdown tooling. Read fresh on every call so dev edits show up on the
# next render without a Rails reload; the read cost is negligible.
#
# Resolved dynamically via User#effective_identity_prompt — not snapshotted
# into agent_configuration. Edits to system_prompt.md go live immediately
# for every trio across every collective.
module Trio
  module SystemPrompt
    extend T::Sig

    PATH = T.let(Rails.root.join("app/services/trio/system_prompt.md"), Pathname)

    sig { returns(String) }
    def self.text
      File.read(PATH)
    end
  end
end
