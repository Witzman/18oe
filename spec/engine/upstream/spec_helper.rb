# frozen_string_literal: true

# Shim for Chris' 18OE specs under spec/engine/upstream/lib (byte-identical copies from upstream, see SOURCE).
# They do `require 'spec_helper'`; upstream's helper pulls in the web stack, so this one only loads the engine.
# Run them with `-I spec/engine/upstream` (bin/test does).
ENV["ENGINE_LOG_LEVEL"] ||= "3"

require "engine"
require "rspec"

Engine::Logger.set_level(Logger::FATAL)

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
