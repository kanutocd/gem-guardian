# frozen_string_literal: true

require_relative "lib/gem/guardian/version"

Gem::Specification.new do |spec|
  spec.name = "gem-guardian"
  spec.version = Gem::Guardian::VERSION
  spec.authors = ["Kenneth Demanawa"]
  spec.email = ["kenneth.c.demanawa@gmail.com"]

  spec.summary = "Consumer-side integrity verification for Ruby gems."
  spec.description = <<~DESC
    Audits Bundler checksum coverage and verifies Ruby gem artifacts against RubyGems SHA256 checksums when needed.
  DESC
  spec.homepage = "https://github.com/kanutocd/gem-guardian"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir.chdir(__dir__) do
    tracked_files = `git ls-files -z`.split("\x0")
    source_files = Dir["lib/**/*", "exe/*", "README.md", "LICENSE.txt", "CHANGELOG.md"]
    (tracked_files + source_files).uniq.reject do |f|
      f.match(%r{\A(?:test|spec|features)/})
    end
  rescue StandardError
    Dir["lib/**/*", "exe/*", "README.md", "LICENSE.txt", "CHANGELOG.md"]
  end

  spec.bindir = "exe"
  spec.executables = ["gem-guardian"]
  spec.require_paths = ["lib"]
end
