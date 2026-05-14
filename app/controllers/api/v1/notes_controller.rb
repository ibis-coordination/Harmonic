# typed: false

module Api::V1
  class NotesController < BaseController
    def index
      index_not_supported_404
    end
  end
end
