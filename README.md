# gem-guardian

[![Gem Version](https://badge.fury.io/rb/gem-guardian.svg)](https://badge.fury.io/rb/gem-guardian)
[![CI](https://github.com/kanutocd/gem-guardian/workflows/CI/badge.svg)](https://github.com/kanutocd/gem-guardian/actions)
[![Ruby Version](https://img.shields.io/badge/ruby-%3E%3D%203.2-ruby.svg)](https://www.ruby-lang.org/en/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)


Consumer-side integrity verification for Ruby gems.

`gem-guardian` verifies downloaded `.gem` artifacts against the SHA256 checksum reported by RubyGems.org. It is intentionally small: no Bundler monkeypatching, no install hooks, and no custom publishing flow required.

## Why

RubyGems.org displays SHA256 checksums for published gem artifacts, and modern Bundler can store checksums in `Gemfile.lock`. But there is still room for a simple consumer-side verification workflow that can be run explicitly in CI or locally.

This MVP verifies:

```text
Gemfile.lock / explicit gem version
    ↓
RubyGems.org expected SHA256
    ↓
Downloaded .gem artifact
    ↓
Local SHA256 comparison
```

This proves that the local artifact matches what RubyGems.org serves. It does **not** yet prove source provenance such as signed tag → CI build → published gem.

## Installation

From a local checkout:

```bash
gem build gem-guardian.gemspec
gem install ./gem-guardian-0.1.0.gem
```

## Usage

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

## Exit codes

- `0` — all verified artifacts matched
- `1` — mismatch, missing checksum, fetch error, or lockfile error
- `2` — CLI usage error

## MVP constraints

- Uses RubyGems.org as the checksum source of truth.
- Downloads artifacts from RubyGems.org `/downloads/<gem-file>.gem`.
- Caches downloaded artifacts under the system temp directory.
- Does not integrate into Bundler install hooks.
- Does not yet verify Sigstore, SLSA, GitHub Actions provenance, or signed git tags.

## Roadmap

- `gem-guardian lock` to emit or update checksum metadata.
- Support Bundler 2.6 `CHECKSUMS` sections as an offline expected-checksum source.
- Provenance verification for gems published through Trusted Publishing.
- GitHub Release checksum/signature discovery.
- Machine-readable JSON output for CI.


## License

[MIT](./LICENSE.txt)


## Code of Conduct

Everyone interacting in the Gem::Guardian project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/kanutocd/gem-guardian/blob/main/CODE_OF_CONDUCT.md).
