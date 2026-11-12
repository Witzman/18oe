# frozen_string_literal: true

# Walking skeleton. No game logic yet — this proves the container builds,
# starts, and answers a healthcheck (which also reports the build id, so a
# deploy can be verified from outside). See 18oe-workshop#2/#3 and
# notes/reference/infrastructure-plan.md for what comes next.

require "sinatra"
require "json"
require_relative "lib/oe/build_id"

set :bind, "0.0.0.0"
set :port, (ENV["PORT"] || 80).to_i
set :host_authorization, { permitted_hosts: ["oe.witzman.de", "127.0.0.1", "localhost"] }

get "/healthz" do
  content_type :json
  JSON.generate(status: "ok", build: Oe::BuildId.value)
end
