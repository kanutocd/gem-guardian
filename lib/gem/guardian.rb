# Gem Guardian provides small, explicit verification and audit helpers for Ruby gems.
#
# The library is intentionally organized as a set of focused objects rather than a
# framework so the CLI, tests, and signatures stay easy to reason about.
# frozen_string_literal: true

require_relative "guardian/version"
require_relative "guardian/error"
require_relative "guardian/checksum"
require_relative "guardian/checksum_provider"
require_relative "guardian/dependency"
require_relative "guardian/lockfile_parser"
require_relative "guardian/rubygems_client"
require_relative "guardian/github_client"
require_relative "guardian/github_release_verifier"
require_relative "guardian/artifact_store"
require_relative "guardian/verifier"
require_relative "guardian/provenance_verifier"
require_relative "guardian/report_builder"
require_relative "guardian/registry"
require_relative "guardian/registry_audit"
require_relative "guardian/result_printer"
require_relative "guardian/cli"
