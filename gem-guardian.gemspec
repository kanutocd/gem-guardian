# frozen_string_literal: true

require_relative "lib/gem/guardian/version"

Gem::Specification.new do |spec|
  spec.name = "gem-guardian"
  spec.version = Gem::Guardian::VERSION
  spec.authors = ["Kenneth Demanawa"]
  spec.email = ["kenneth.c.demanawa@gmail.com"]

  spec.summary = "Gem integrity and supply-chain verification for Ruby."
  spec.description = <<~DESC
    Verifies gem integrity using lockfile, registry, and artifact checksums,
    audits Bundler checksum coverage, and reports supply-chain provenance
    when available.
  DESC

  spec.homepage = "https://kanutocd.github.io/gem-guardian"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["documentation_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/kanutocd/gem-guardian"
  spec.metadata["changelog_uri"] = "#{spec.metadata["source_code_uri"]}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(__dir__) do
    tracked_files = `git ls-files -z`.split("\x0")
    source_files = Dir["lib/**/*", "sig/**/*", "exe/*", "README.md", "LICENSE.txt", "CHANGELOG.md"]
    (tracked_files + source_files).uniq.reject do |f|
      f.match(%r{\A(?:test|spec|features)/})
    end
  rescue StandardError
    Dir["lib/**/*", "sig/**/*", "exe/*", "README.md", "LICENSE.txt", "CHANGELOG.md"]
  end

  spec.bindir = "exe"
  spec.executables = ["gem-guardian"]
  spec.require_paths = ["lib"]
end
