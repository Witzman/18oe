# frozen_string_literal: true

# #564 / #563 Task 1. lib/engine is generated, never edited by hand:
#   upstream tobymao/18xx @ sha, minus foreign titles, plus engine/local/*.patch (load paths only),
#   plus engine/patches/*.patch (rules/features 18xx lacks; each a later upstream PR).
# engine/PIN holds the sha, engine/MANIFEST the sha256 of every generated file.
require "digest"
require "fileutils"
require "open3"
require "tmpdir"

module EngineSync
  KEEP_TITLES = %w[g_18_oe g_18_oe_uk_fr].freeze
  UPSTREAM_URL = "https://github.com/tobymao/18xx.git"
  Error = Class.new(StandardError)

  module_function

  def run!(*cmd, chdir: nil)
    out, status = Open3.capture2e(*cmd, **(chdir ? { chdir: chdir } : {}))
    raise Error, "#{cmd.join(' ')} failed:\n#{out}" unless status.success?

    out
  end

  # Files of the generated tree, relative to root, sorted.
  def generated_files(root)
    files = Dir.glob(File.join(root, "lib", "engine", "**", "*"), File::FNM_DOTMATCH)
               .select { |f| File.file?(f) }
    files << File.join(root, "lib", "engine.rb") if File.file?(File.join(root, "lib", "engine.rb"))
    files.map { |f| f.delete_prefix("#{root}/") }.sort
  end

  def manifest_lines(root)
    generated_files(root).map { |f| "#{Digest::SHA256.file(File.join(root, f)).hexdigest}  #{f}" }
  end

  # Returns the list of problems (empty = clean).
  def check(root)
    path = File.join(root, "engine", "MANIFEST")
    return ["engine/MANIFEST missing (run bin/engine-sync <sha>)"] unless File.file?(path)

    expected = File.readlines(path, chomp: true).to_h { |l| l.split("  ", 2).reverse }
    actual = manifest_lines(root).to_h { |l| l.split("  ", 2).reverse }
    problems = []
    (expected.keys | actual.keys).sort.each do |f|
      if !actual.key?(f) then problems << "missing:  #{f}"
      elsif !expected.key?(f) then problems << "extra:    #{f}"
      elsif expected[f] != actual[f] then problems << "changed:  #{f}"
      end
    end
    problems
  end

  def foreign_title?(rel)
    m = rel.match(%r{\Alib/engine/game/(g_[^/]+?)(?:\.rb)?(?:/|\z)})
    m && !KEEP_TITLES.include?(m[1])
  end

  def fetch_upstream(sha, upstream, tmp)
    return upstream if upstream

    dir = File.join(tmp, "clone")
    run!("git", "clone", "--quiet", "--filter=blob:none", "--no-checkout", UPSTREAM_URL, dir)
    dir
  end

  def sync(root, sha, upstream: nil)
    Dir.mktmpdir("engine-sync") do |tmp|
      src = fetch_upstream(sha, upstream, tmp)
      full = run!("git", "rev-parse", "--verify", "#{sha}^{commit}", chdir: src).strip
      stage = File.join(tmp, "stage")
      FileUtils.mkdir_p(stage)
      tar = File.join(tmp, "up.tar")
      run!("git", "archive", "--format=tar", "-o", tar, full, "lib/engine.rb", "lib/engine", chdir: src)
      run!("tar", "-xf", tar, "-C", stage)
      generated_files(stage).select { |f| foreign_title?(f) }.each { |f| FileUtils.rm_f(File.join(stage, f)) }
      Dir.glob(File.join(stage, "lib/engine/**/*/"), File::FNM_DOTMATCH).sort.reverse.each do |d|
        Dir.rmdir(d) if File.directory?(d) && (Dir.children(d)).empty?
      end
      %w[local patches].each do |kind|
        Dir.glob(File.join(root, "engine", kind, "*.patch")).sort.each do |p|
          out, status = Open3.capture2e("patch", "-p1", "--no-backup-if-mismatch", "-s", "-i", p, chdir: stage)
          raise Error, "patch #{kind}/#{File.basename(p)} does not apply to #{full}:\n#{out}" unless status.success?
        end
      end
      FileUtils.rm_rf(File.join(root, "lib", "engine"))
      FileUtils.rm_f(File.join(root, "lib", "engine.rb"))
      FileUtils.mkdir_p(File.join(root, "lib"))
      FileUtils.cp_r(File.join(stage, "lib", "engine"), File.join(root, "lib", "engine"))
      FileUtils.cp(File.join(stage, "lib", "engine.rb"), File.join(root, "lib", "engine.rb"))
      FileUtils.mkdir_p(File.join(root, "engine"))
      File.write(File.join(root, "engine", "PIN"), "#{full}\n")
      File.write(File.join(root, "engine", "MANIFEST"), manifest_lines(root).join("\n") + "\n")
      full
    end
  end
end
