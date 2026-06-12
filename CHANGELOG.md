# Changelog

## [Unreleased]

- Discover GitHub Release checksum and signature assets.
- Verify signed Git tags and GitHub release attestations when provenance exposes a GitHub tag.

## [0.2.0] - 2026-06-12

- Add `--json` output for CI-friendly verification reports.
- Add opt-in Trusted Publishing provenance verification for RubyGems releases.
- Verify provenance through RubyGems attestations for supported releases.

## [0.1.1] - 2026-06-12

- Parse Bundler `CHECKSUMS` entries from `Gemfile.lock`.
- Audit lockfiles for missing checksum coverage and report fallback verification.
- Raise test coverage to 95%+ line and branch.
- Curate `sig/` outputs so `rbs validate` passes cleanly.
- Add GitHub Actions Ruby matrix for `3.2`, `3.3`, `3.4`, and `4.0`.
- Run `rbs:validate` in CI.

## [0.1.0] - 2026-06-12

- Initial MVP codebase.
- Verify explicit gems or all gems in `Gemfile.lock`.
- Fetch expected SHA256 checksums from RubyGems.org versions API.
- Fetch `.gem` artifacts from RubyGems.org and verify SHA256 locally.
