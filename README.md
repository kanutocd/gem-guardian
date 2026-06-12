# gem-guardian

[![Gem Version](https://badge.fury.io/rb/gem-guardian.svg)](https://badge.fury.io/rb/gem-guardian)
[![CI](https://github.com/kanutocd/gem-guardian/workflows/CI/badge.svg)](https://github.com/kanutocd/gem-guardian/actions)
[![Ruby Version](https://img.shields.io/badge/ruby-%3E%3D%203.2-ruby.svg)](https://www.ruby-lang.org/en/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)


Consumer-side integrity verification for Ruby gems.

`gem-guardian` audits Bundler checksum coverage, verifies `.gem` artifacts against RubyGems SHA256 data when needed, and can verify Trusted Publishing provenance for supported releases, including GitHub release checksum/signature discovery and signed-tag attestation checks when the release data exposes them. It stays intentionally small: no Bundler monkeypatching, no install hooks, and no custom publishing flow required.

## Why

RubyGems.org displays SHA256 checksums for published gem artifacts, Bundler 2.6 can store and enforce checksums in `Gemfile.lock`, and RubyGems now exposes attestation data for Trusted Publishing releases. That means the most useful current release is an audit and verification tool that tells you whether your bundle and release metadata are actually protected.

This 0.2.0 scope is:

```text
Gemfile.lock
    ↓
CHECKSUMS coverage audit
    ↓
RubyGems.org checksum comparison when needed
    ↓
Trusted Publishing provenance verification when available
    ↓
Actionable report for CI or local review
```

This reports whether your lockfile is using Bundler checksum protection, whether any locked gems are missing expected checksum data, whether RubyGems exposes Trusted Publishing provenance for the gem being verified, and whether GitHub release assets and tag attestations are available for the release being inspected.

## Installation

From a local checkout:

```bash
gem build gem-guardian.gemspec
gem install ./gem-guardian-0.2.0.gem
```

## Usage

Build and install the current release from a local checkout:

```bash
gem build gem-guardian.gemspec
gem install ./gem-guardian-0.2.0.gem
gem-guardian version
```

Show the built-in help:

```bash
gem-guardian help
gem-guardian --help
```

Prepare a locked project for checksum auditing:

```bash
bundle lock --add-checksums
```

Verify all gems in `Gemfile.lock`:

```bash
gem-guardian verify
```

Verify a specific gem version:

```bash
gem-guardian verify cdc-sidekiq:0.1.1
gem-guardian verify ratomic:0.4.1
```

Verify a platform gem:

```bash
gem-guardian verify nokogiri:1.18.9:x86_64-linux
```

Use a non-default lockfile:

```bash
gem-guardian verify --lockfile path/to/Gemfile.lock
```

Emit JSON for CI:

```bash
gem-guardian verify --json
gem-guardian verify --json --provenance
```

When you verify a lockfile that already contains Bundler `CHECKSUMS`, `gem-guardian` reports coverage and compares the locked checksum to the downloaded artifact. When a checksum is missing, it falls back to RubyGems.org metadata and marks that verification accordingly.

Use `--provenance` to inspect Trusted Publishing metadata when RubyGems exposes it. Unsupported gems are reported, but they do not fail the run unless the provenance data is present and mismatched.

## Exit codes

- `0` — all verified artifacts matched
- `1` — mismatch, missing checksum, fetch error, or lockfile error
- `2` — CLI usage error

## MVP constraints

- Audits `Gemfile.lock` for Bundler `CHECKSUMS` coverage.
- Uses RubyGems.org as a fallback checksum source when the lockfile is incomplete or an explicit gem is supplied.
- Downloads artifacts from RubyGems.org `/downloads/<gem-file>.gem` only when verification is needed.
- Caches downloaded artifacts under the system temp directory.
- Does not integrate into Bundler install hooks.
- GitHub Release checksum/signature discovery and signed tag/release attestation checks are supported when the release metadata is available.

## Roadmap

- Expand release provenance checks to additional publishing workflows beyond GitHub release provenance.


## License

[MIT](./LICENSE.txt)


## Code of Conduct

Everyone interacting in the Gem::Guardian project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/kanutocd/gem-guardian/blob/main/CODE_OF_CONDUCT.md).
