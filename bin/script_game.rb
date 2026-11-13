# frozen_string_literal: true

# Scripted game over the real HTTP API (#132).
#   bin/script-game --spawn [--slice s1] [--players 4] [--seed 1]
#       starts a local server (in-memory database, bots off), registers the
#       players with an invite code, plays one game from the auction to the end
#       and prints which round/step/action combinations were executed.
#   (--game N plays only the Nth game of the slice)
#   bin/script-game --base http://127.0.0.1:4567 --invite CODE
#       the same against a running instance (it needs OE_INVITE_CODE's value;
#       the accounts "script-<seed>-<n>" stay behind on that instance).
# Exit status 0 only if the game ended regularly, nothing was rejected and no
# target combination of the slice is missing.

ENV["ENGINE_LOG_LEVEL"] ||= "3"
require "optparse"
require "securerandom"
require "socket"
require "oe/script_game"

opts = { slice: "s1", players: 4, seed: 1, seed_given: false, base: nil, spawn: false, invite: ENV["OE_INVITE_CODE"], max_actions: 20_000 }
OptionParser.new do |o|
  o.on("--slice NAME") { |v| opts[:slice] = v }
  o.on("--players N", Integer) { |v| opts[:players] = v }
  o.on("--seed N", Integer) { |v| opts[:seed] = v; opts[:seed_given] = true }
  o.on("--base URL") { |v| opts[:base] = v }
  o.on("--spawn") { opts[:spawn] = true }
  o.on("--game N", Integer) { |v| opts[:only] = v - 1 }
  o.on("--invite CODE") { |v| opts[:invite] = v }
  o.on("--max-actions N", Integer) { |v| opts[:max_actions] = v }
end.parse!

abort "give --spawn or --base URL" unless opts[:spawn] || opts[:base]

server = nil
if opts[:spawn]
  port = TCPServer.open("127.0.0.1", 0) { |s| s.addr[1] }
  opts[:invite] ||= SecureRandom.hex(8)
  opts[:base] = "http://127.0.0.1:#{port}"
  env = { "APP_ENV" => "development", "RACK_ENV" => "development", "PORT" => port.to_s, "OE_BOTS" => "off",
          "OE_INVITE_CODE" => opts[:invite], "ENGINE_LOG_LEVEL" => "3", "DATABASE_PATH" => nil }
  server = Process.spawn(env, RbConfig.ruby, "-I", "lib", File.expand_path("../app.rb", __dir__), %i[out err] => File::NULL)
  at_exit { Process.kill("TERM", server) rescue nil }
  60.times do
    break if (Net::HTTP.get_response(URI("#{opts[:base]}/healthz")) rescue nil)&.code == "200"

    sleep 0.5
  end
end

abort "no invite code (OE_INVITE_CODE or --invite)" unless opts[:invite]
password = SecureRandom.hex(12)
clients = {}
opts[:players].times do |i|
  name = "script-#{opts[:seed]}-#{i + 1}"
  client = Oe::ScriptGame::Clients::Net.new(opts[:base])
  status, body = client.call(:post, "/register", { name: name, email: "#{name}@example.test", password: password, code: opts[:invite] })
  abort "register #{name} failed: #{status} #{body.inspect}" unless status == 201
  clients[body["id"]] = client
end

ok = true
(opts[:only] ? [opts[:only]] : (0...Oe::ScriptGame.games(opts[:slice])).to_a).each do |index|
  result = Oe::ScriptGame.new(clients: clients, slice: opts[:slice], game: index, seed: opts[:seed_given] && opts[:seed],
                              max_actions: opts[:max_actions],
                              log: ->(seq, round, step, _a) { warn "  seq #{seq} #{round}/#{step}" if (seq % 500).zero? }).run
  puts Oe::ScriptGame::Report.lines(result), "", "=" * 78, ""
  ok &&= result.ok?
end
exit(ok ? 0 : 1)
