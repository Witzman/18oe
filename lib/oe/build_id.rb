# frozen_string_literal: true

require "digest"

module Oe
  # A fingerprint of the shipped source, computed from file contents so it is
  # the same in a git checkout and inside the Docker image (which has no .git).
  # /healthz reports it; bin/build-id prints it for the local tree, which is
  # how a deploy is verified from outside (see 18oe-workshop#41).
  module BuildId
    ROOT = File.expand_path("../..", __dir__)
    PATTERNS = ["app.rb", "Gemfile.lock", "VERSION", "lib/**/*"].freeze

    def self.files
      PATTERNS.flat_map { |pattern| Dir.glob(pattern, base: ROOT) }
              .select { |path| File.file?(File.join(ROOT, path)) }
              .reject { |path| path.end_with?(".md") } # .dockerignore drops *.md
              .uniq.sort
    end

    def self.compute
      digest = Digest::SHA256.new
      files.each do |path|
        digest << path << "\0" << File.binread(File.join(ROOT, path)) << "\0"
      end
      digest.hexdigest[0, 12]
    end

    def self.value
      @value ||= compute
    end
  end
end
