# frozen_string_literal: true

module Oe
  # Roadmap version of the product (#271): the single `VERSION` file in the repo root,
  # also read by the frontend build (web/build.mjs). "0.1.0-dev" while a version is being
  # built; the release tag (v0.1.0, ...) is set on the merge commit of main (see README).
  module Version
    FILE = File.expand_path("../../VERSION", __dir__)

    def self.value
      @value ||= File.read(FILE).strip
    end
  end
end
