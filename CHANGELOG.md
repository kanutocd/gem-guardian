# Changelog

## Unreleased

## [0.3.1] Unreleased

- Tighten gemspec positioning around lockfile, registry, artifact checksum verification, and supply-chain provenance.
- Add checksum-provider branch coverage for the default `Net::HTTP` path used by publisher checksum URLs.
- Keep the known JSON stdout noise issue tracked as a follow-up rather than blocking the checksum-provider release.

- Implemented checksum-source triage: lockfile, registry, and artifact.
- Added optional registry SHA256 cross-check in lockfile mode.
- Updated JSON checksum payloads with `registry_sha256`.
- Clarified README trust model around `PASS` vs `RECORDED`.

- Resolve explicit private-registry checksums through Bundler/RubyGems Compact Index metadata (`/info/<gem>`) when RubyGems.org-style versions APIs are unavailable.
- Fall back to artifact digest recording for explicit private-registry gems when no independent registry checksum is exposed.
- Skip Trusted Publishing provenance lookups for non-RubyGems.org sources so private registry gems report unsupported provenance instead of API 404 errors.

- Improve YARD documentation for CLI lockfile filtering and progress helpers.
- Expand README with real-world Rails provenance results, private registry behavior, lockfile filtering, CI/CD guidance, and registry audit usage.

- Fix registry audit source handling by preserving `Gem::SourceList` for `Gem::SpecFetcher`.
- Add regression coverage for registry source normalization and private/source-specific artifact paths.
- Add focused branch coverage for RubyGems client edge cases around source resolution, redirects, authentication, and provenance parsing.

## [0.3.0] - 2026-06-12

- Discover GitHub Release checksum and signature assets.
- Verify signed Git tags and GitHub release attestations when provenance exposes a GitHub tag.
- Fall back to version-derived release tags when RubyGems provenance exposes only a commit SHA.
- Add GitHub release metadata to JSON and human-readable provenance output when available.
- Package the new GitHub verifier classes into the released gem.

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
