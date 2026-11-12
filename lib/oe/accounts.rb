# frozen_string_literal: true

require "rack/utils"

module Oe
  # Hardcoded PoC accounts (#33/#4). No registration, no passwords: whoever
  # knows the access code may pick any account. Names come from the
  # environment, never from the repo.
  module Accounts
    # Neutral placeholders for local dev and tests only.
    DEFAULT = "alice:Alice,bob:Bob,carol:Carol,dave:Dave".freeze

    # "id:Display Name,id2:Name 2" => { "id" => "Display Name", ... }
    def self.parse(spec)
      spec.to_s.split(",").each_with_object({}) do |entry, acc|
        id, name = entry.split(":", 2).map(&:strip)
        next if id.nil? || id.empty?

        acc[id] = name.nil? || name.empty? ? id : name
      end
    end

    def self.all(env = ENV)
      parse(env["OE_ACCOUNTS"] || DEFAULT)
    end

    def self.find(id, env = ENV)
      name = all(env)[id.to_s]
      name && { "id" => id.to_s, "name" => name }
    end

    # Constant-time check. An unset/empty OE_ACCESS_CODE means "no code
    # required" (dev/test only; production refuses to boot without it).
    def self.access_ok?(given, env = ENV)
      expected = env["OE_ACCESS_CODE"].to_s
      return true if expected.empty?

      Rack::Utils.secure_compare(expected, given.to_s)
    end
  end
end
