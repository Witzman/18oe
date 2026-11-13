# frozen_string_literal: true

require "base64"
require "openssl"
require "rack/utils"
require "securerandom"

module Oe
  # Player accounts (#208): registered with an invite code, stored in the
  # SQLite `accounts` table. Passwords are never stored in clear, only as a
  # salted scrypt hash (OpenSSL::KDF from the Ruby stdlib, no extra gem).
  module Accounts
    NAME_RANGE = (2..30)
    PASSWORD_RANGE = (8..200)
    EMAIL_MAX = 254
    EMAIL_FORMAT = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/
    SCRYPT = { n: 2**15, r: 8, p: 1, length: 32 }.freeze

    class Invalid < StandardError
      attr_reader :code

      def initialize(code, message)
        @code = code
        super(message)
      end
    end

    # Constant-time check of the shared invite code (OE_INVITE_CODE). An unset
    # or empty code means nobody can register.
    def self.invite_ok?(given, env = ENV)
      expected = env["OE_INVITE_CODE"].to_s
      return false if expected.empty? || !given.is_a?(String)

      Rack::Utils.secure_compare(expected, given)
    end

    def self.normalize_email(email)
      email.to_s.strip.downcase
    end

    def self.normalize_name(name)
      name.to_s.strip.gsub(/\s+/, " ")
    end

    # Returns [name, email]; raises Invalid for bad input.
    def self.validate(name:, email:, password:)
      name = normalize_name(name)
      email = normalize_email(email)
      raise Invalid.new("invalid_name", "name must be #{NAME_RANGE.min} to #{NAME_RANGE.max} characters, no control characters or @") unless NAME_RANGE.cover?(name.length) && !name.match?(/[[:cntrl:]@]/)
      raise Invalid.new("invalid_email", "e-mail address looks invalid") unless email.length <= EMAIL_MAX && email.match?(EMAIL_FORMAT)
      unless password.is_a?(String) && PASSWORD_RANGE.cover?(password.length)
        raise Invalid.new("invalid_password", "password must be #{PASSWORD_RANGE.min} to #{PASSWORD_RANGE.max} characters")
      end

      [name, email]
    end

    # Raises Invalid (name_taken / registration_failed). A duplicate e-mail gets
    # a deliberately neutral answer: no hint whether an address is registered.
    def self.register(store, name:, email:, password:, id: nil)
      name, email = validate(name: name, email: email, password: password)
      store.create_account(id: id || "u#{SecureRandom.hex(6)}", name: name, email: email, password_hash: hash_password(password))
    rescue Store::Duplicate => e
      raise Invalid.new("name_taken", "this name is already taken") if e.field == :name

      raise Invalid.new("registration_failed", "registration not possible with these details")
    end

    # login = e-mail or name. Returns {"id","name"} or nil. Always does one
    # hash verification so timing does not tell whether the login exists.
    def self.authenticate(store, login, password)
      row = store.account_by_login(normalize_email(login), normalize_name(login))
      ok = verify_password(password.to_s, row ? row["password_hash"] : DUMMY_HASH)
      row && ok ? public_view(row) : nil
    end

    def self.find(store, id)
      row = id && store.account(id.to_s)
      row && public_view(row)
    end

    # Looks up one account by what a creator typed (#212): name or e-mail,
    # case-insensitive. Returns {"id","name"} or nil. Never lists accounts.
    def self.resolve(store, text)
      return nil unless text.is_a?(String)

      text = text.strip
      return nil if text.empty? || text.length > EMAIL_MAX

      row = text.include?("@") ? store.account_by_login(normalize_email(text), nil) : store.account_by_login(nil, normalize_name(text))
      row && public_view(row)
    end

    def self.public_view(row)
      { "id" => row["id"], "name" => row["name"] }
    end

    def self.hash_password(password, salt: SecureRandom.random_bytes(16))
      digest = OpenSSL::KDF.scrypt(password, salt: salt, N: SCRYPT[:n], r: SCRYPT[:r], p: SCRYPT[:p], length: SCRYPT[:length])
      ["scrypt", SCRYPT[:n], SCRYPT[:r], SCRYPT[:p], Base64.strict_encode64(salt), Base64.strict_encode64(digest)].join("$")
    end

    def self.verify_password(password, stored)
      _, n, r, p, salt, digest = stored.split("$")
      salt = Base64.strict_decode64(salt)
      expected = Base64.strict_decode64(digest)
      actual = OpenSSL::KDF.scrypt(password, salt: salt, N: n.to_i, r: r.to_i, p: p.to_i, length: expected.bytesize)
      Rack::Utils.secure_compare(expected, actual)
    rescue ArgumentError, OpenSSL::KDF::KDFError
      false
    end

    DUMMY_HASH = hash_password("dummy-password-for-timing")

    # In-memory failure counter per key (IP), single Puma process (#34).
    # Used for guessing the invite code and for password guessing.
    class RateLimit
      def initialize(max:, window:)
        @max = max
        @window = window
        @hits = Hash.new { |h, k| h[k] = [] }
        @mutex = Mutex.new
      end

      def blocked?(key)
        @mutex.synchronize { prune(key).size >= @max }
      end

      def fail!(key)
        @mutex.synchronize { prune(key) << Time.now.to_f }
      end

      def reset!
        @mutex.synchronize { @hits.clear }
      end

      private

      def prune(key)
        list = @hits[key]
        list.reject! { |t| t < Time.now.to_f - @window }
        list
      end
    end
  end
end
