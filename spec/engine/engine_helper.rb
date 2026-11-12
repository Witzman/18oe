# frozen_string_literal: true

# Shared setup for the engine specs. Deliberately independent of spec_helper
# (no Sinatra app, no rack-test): the engine specs only need the engine.
# The upstream engine specs use the global `describe` DSL, so monkey patching
# is left enabled here.

# The engine logs every action at DEBUG unless told otherwise (3 = ERROR).
ENV["ENGINE_LOG_LEVEL"] ||= "3"

require "engine"
require "rspec"

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
