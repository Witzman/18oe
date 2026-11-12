# frozen_string_literal: true

# Walking skeleton. No game logic yet — this proves the container builds,
# starts, and answers a healthcheck. See 18oe-workshop#2/#3 and
# notes/reference/infrastructure-plan.md for what comes next.

require "sinatra"

set :bind, "0.0.0.0"
set :port, (ENV["PORT"] || 80).to_i
set :host_authorization, { permitted_hosts: ["oe.witzman.de", "127.0.0.1", "localhost"] }

get "/healthz" do
  content_type :json
  '{"status":"ok"}'
end
