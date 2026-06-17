# gem-guardian

[![Gem Version](https://badge.fury.io/rb/gem-guardian.svg)](https://badge.fury.io/rb/gem-guardian)
[![CI](https://github.com/kanutocd/gem-guardian/workflows/CI/badge.svg)](https://github.com/kanutocd/gem-guardian/actions)
[![Ruby Version](https://img.shields.io/badge/ruby-%3E%3D%203.2-ruby.svg)](https://www.ruby-lang.org/en/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Consumer-side integrity and provenance verification for Ruby gems.

`gem-guardian` audits Bundler checksum coverage, verifies `.gem` artifacts against lockfile and registry checksum sources, records artifact digests when no independent checksum exists, and reports Trusted Publishing provenance when the registry exposes it. It is intentionally small: no Bundler monkeypatching, no install hooks, and no custom publishing flow required.

## Why

Ruby now has several useful supply-chain signals:

- RubyGems.org exposes SHA256 checksums for published gem artifacts.
- Bundler can store and enforce checksums in `Gemfile.lock`.
- RubyGems exposes provenance metadata for gems published through Trusted Publishing.

The missing piece is consumer-side visibility.

`gem-guardian` helps answer:

```text
Did the artifact match my lockfile checksum?
Did it also match registry or publisher checksum metadata?
Was only an artifact digest recorded?
Was it published through Trusted Publishing?
Which repository, workflow, and commit produced it?
```


## Integrity model

`gem-guardian` separates checksum sources from the downloaded artifact. The downloaded `.gem` is always hashed locally. A result is considered verified only when that artifact digest is compared with an independent expected digest.

| Level | Required checks | Output | Meaning |
| --- | --- | --- | --- |
| Lockfile + registry + artifact | `lockfile SHA256 == registry SHA256 == artifact SHA256` | `PASS`, `source lockfile`, `registry ...` | Strongest path. The project lockfile and registry metadata agree with the downloaded artifact. |
| Lockfile + artifact | `lockfile SHA256 == artifact SHA256` | `PASS`, `source lockfile` | Strong project-level verification. Works even when the registry does not expose checksum metadata. |
| Registry + artifact | `registry SHA256 == artifact SHA256` | `PASS`, `source registry` | Registry-anchored verification for ad-hoc gem checks without a lockfile. |
| Artifact only | `artifact SHA256` only | `RECORDED`, `source artifact` | Informational only. The artifact was hashed, but no independent checksum source was available. |

Verification priority is:

```text
lockfile > registry > artifact
```

`RECORDED` is intentionally not called `PASS`: there is no independent checksum to compare against.

## Real-world example

Against a freshly generated Rails 8 application with lockfile checksums enabled:

```bash
bundle lock --add-checksums
gem-guardian verify --provenance
```

Observed result:

```text
CHECKSUMS coverage: 142/142

PROVENANCE PASS:        35
PROVENANCE UNSUPPORTED: 107
```

| Signal | Coverage |
| --- | ---: |
| Bundler lockfile checksums | 142 / 142 (100%) |
| Trusted Publishing provenance | 35 / 142 (24.6%) |
| Provenance unavailable | 107 / 142 (75.4%) |

This illustrates the distinction between integrity and provenance:

```text
Integrity:
  Did I receive the expected artifact?

Provenance:
  Who built and published this artifact?
```

A dependency graph can have complete checksum coverage while still having limited provenance visibility.

## Installation

Install from RubyGems:

```bash
gem install gem-guardian
```

Or build from a local checkout:

```bash
gem build gem-guardian.gemspec
gem install ./gem-guardian-0.3.1.gem
```

## Quick start

Prepare a Bundler project for checksum auditing:

```bash
bundle lock --add-checksums
```

Verify the lockfile:

```bash
gem-guardian verify
```

Verify integrity and provenance:

```bash
gem-guardian verify --provenance
```

Emit JSON for CI:

```bash
gem-guardian verify --json --provenance
```

## Usage

Show help:

```bash
gem-guardian help
gem-guardian --help
```

Verify a specific published gem:

```bash
gem-guardian verify rails:8.1.3
gem-guardian verify cdc-sidekiq:0.1.1
gem-guardian verify ratomic:0.4.1
```

Verify a platform-specific gem:

```bash
gem-guardian verify nokogiri:1.18.9:x86_64-linux
```

Verify all gems in a non-default lockfile:

```bash
gem-guardian verify --lockfile path/to/Gemfile.lock
```

Verify only selected gems from a lockfile:

```bash
gem-guardian verify --lockfile path/to/Gemfile.lock --provenance mammoth:0.1.1
gem-guardian verify --lockfile path/to/Gemfile.lock --provenance nokogiri:1.18.9:x86_64-linux
```

When a platform is omitted in lockfile mode, `gem-guardian` matches every locked platform for that gem and version.

## How verification works

`gem-guardian` separates three integrity signals:

1. **Lockfile checksum** — expected SHA256 comes from Bundler's `Gemfile.lock` `CHECKSUMS` section.
2. **Registry or publisher checksum** — expected SHA256 comes from registry metadata or a configured checksum provider when available.
3. **Artifact digest** — SHA256 is computed from the downloaded `.gem` file.

The artifact digest is always computed locally. Lockfile and registry/publisher checksums are independent trust anchors used for comparison.

### Lockfile mode

```bash
gem-guardian verify --lockfile Gemfile.lock
```

In lockfile mode, `gem-guardian` treats `Gemfile.lock` as the primary trust anchor:

```text
expected SHA256 = Gemfile.lock CHECKSUMS
actual SHA256   = downloaded .gem artifact
```

If the registry also exposes a checksum, `gem-guardian` performs a stronger three-way check:

```text
lockfile SHA256 == registry SHA256 == artifact SHA256
```

This mode is the preferred CI/CD path because Bundler has already recorded the expected artifact digest for the application. It is also registry-agnostic: the registry only needs to resolve and serve the artifact after the checksum has been committed to the lockfile.

A successful lockfile-only verification reports:

```text
PASS cdc-orchestrator-pro 0.1.0 ruby
     sha256 fa82bd6f...
     source lockfile
```

If a registry or publisher checksum is also available, the output includes the cross-check source:

```text
PASS cdc-sidekiq 0.1.1 ruby
     sha256 d91d298d...
     source lockfile
     registry d91d298d...
     provider rubygems-api
     verify https://rubygems.org/api/v1/versions/cdc-sidekiq.json
```

### Explicit gem mode

```bash
gem-guardian verify GEM:VERSION[:PLATFORM]
```

In explicit mode, there is no lockfile trust anchor. `gem-guardian` resolves the gem from the configured RubyGems source list, downloads the `.gem` artifact, computes its SHA256 digest, and then behaves as follows:

```text
If registry or publisher checksum exists:
  expected SHA256 = registry/publisher checksum
  actual SHA256   = downloaded artifact checksum
  result          = PASS or FAIL

If no independent checksum is available:
  expected SHA256 = none
  actual SHA256   = downloaded artifact checksum
  result          = RECORDED
```

`RECORDED` means the artifact was found and hashed, but there was no independent checksum source to compare against. It is useful inventory data, not proof of integrity.

Example with registry checksum support:

```text
PASS cdc-sidekiq 0.1.1 ruby
     sha256 d91d298d...
     source registry
```

Example without registry checksum support:

```text
RECORDED cdc-orchestrator-pro 0.1.0 ruby
     sha256 fa82bd6f...
     source artifact
```

### Checksum providers

Registry and publisher checksums are obtained through checksum providers. Built-in providers include:

- `rubygems-api` — RubyGems.org-style versions API.
- `compact-index` — RubyGems/Bundler compact index metadata when available.
- `url` — publisher-controlled checksum files, useful for private or commercial gem distribution.

Provider metadata is included in JSON output as:

```json
{
  "registry_sha256": "d91d298d...",
  "registry_checksum_provider": "rubygems-api",
  "registry_checksum_uri": "https://rubygems.org/api/v1/versions/cdc-sidekiq.json"
}
```

The URL provider is intentionally generic so a publisher can expose a checksum file without implementing RubyGems.org's metadata API.
A commercial or private registry can expose something like:

```text
https://example.com/checksums/{filename}.sha256
```

with contents such as:

```text
<sha256>  <filename>
```

### Project configuration

Project-level checksum providers can be declared in `.gem-guardian.yml`:

```yaml
checksum_providers:
  - name: awesome-gems-registry
    source: https://gems.everything-is-awesome.com/
    template: https://gems.everything-is-awesome.com/checksums/{filename}.sha256
```

The `source` field scopes the provider to gems resolved from that registry, so a private checksum URL is not queried for unrelated public gems. The `template` field supports these placeholders:

- `{name}`
- `{version}`
- `{platform}`
- `{filename}`

For example, a locked `mammoth-pro` artifact named `mammoth-pro-1.0.0.gem` would resolve to:

```text
https://gems.everything-is-awesome.com/checksums/mammoth-pro-1.0.0.gem.sha256
```

This lets private publishers integrate with gem-guardian without implementing the RubyGems.org versions API. When the checksum file is available, explicit mode can verify:

```text
publisher checksum == artifact checksum
```

and lockfile mode can perform the strongest path:

```text
lockfile checksum == publisher checksum == artifact checksum
```

Set `GEM_GUARDIAN_CONFIG=/path/to/config.yml` to load configuration from a non-default location.

## Provenance mode

```bash
gem-guardian verify --provenance GEM:VERSION
gem-guardian verify --lockfile Gemfile.lock --provenance
```

Checksum verification and provenance verification are related but separate. Checksums answer:

```text
Did the artifact bytes match an expected digest?
```

Provenance answers:

```text
Who built and published this artifact?
Which repository, workflow, and commit produced it?
```

When RubyGems exposes Trusted Publishing provenance, `gem-guardian` reports information such as:

- repository
- workflow
- commit/ref
- issuer
- subject

Unsupported provenance is reported as unsupported and does not fail the run. Provenance mismatches and verifier errors fail the run.

## Private registries

`gem-guardian` uses RubyGems' configured source list for source discovery. That means explicit and lockfile verification can work with RubyGems-compatible private registries such as GitHub Packages, Gemfury, CodeArtifact, Artifactory, or self-hosted gem servers when they are present in `gem sources`.

```bash
gem sources --list
gem-guardian verify cdc-orchestrator-pro:0.1.0
```

Private registries vary in how much metadata they expose. Some expose enough metadata for registry-checksum verification. Others expose enough index data to resolve and download a gem, but do not expose an independent SHA256 checksum. Publishers can also provide checksums outside the registry through a configured checksum provider.

In explicit mode, that distinction is reflected in the result:

```text
PASS     source registry   # registry/publisher checksum matched artifact checksum
RECORDED source artifact   # artifact was hashed, but no independent checksum was available
```

For stronger verification of private gems, prefer lockfile mode after running:

```bash
bundle lock --add-checksums
```

Once the checksum is recorded in `Gemfile.lock`, `gem-guardian` can verify the downloaded artifact against the lockfile checksum even if the registry does not expose checksum metadata later:

```bash
gem-guardian verify --lockfile Gemfile.lock cdc-orchestrator-pro:0.1.0
```

```text
PASS cdc-orchestrator-pro 0.1.0 ruby
     sha256 fa82bd6f...
     source lockfile
CHECKSUMS coverage: 1/1
```

If the private registry or publisher also exposes a checksum, lockfile mode performs the stronger three-way comparison:

```text
lockfile SHA256 == registry SHA256 == artifact SHA256
```

## Registry audit research script

The repository includes an experimental registry audit script for ecosystem research:

```bash
./script/registry_provenance_audit.rb
```

By default it inspects the RubyGems-compatible registries visible through `Gem.sources`.

Limit the scan:

```bash
MAX_GEMS=100 ./script/registry_provenance_audit.rb
```

Restrict the scan to one source:

```bash
REGISTRY_SOURCE=https://rubygems.org/ MAX_GEMS=100 ./script/registry_provenance_audit.rb
```

This script is intentionally separate from the main CLI. It is useful for answering questions such as:

```text
Which gems visible from my configured registries expose Trusted Publishing provenance?
Which gems have checksum verification but no provenance metadata?
```

## CI/CD integration

Example GitHub Actions steps:

```yaml
- name: Add Bundler checksums
  run: bundle lock --add-checksums

- name: Verify gem integrity and provenance
  run: gem-guardian verify --json --provenance
```

This can be used as a security job to:

- verify Bundler checksum coverage
- compare lockfile checksums with downloaded artifacts
- cross-check registry or publisher checksums when available
- detect artifact checksum mismatches
- audit Trusted Publishing adoption
- archive JSON results for later review

## Exit codes

- `0` — all required verification checks passed
- `1` — mismatch, missing checksum, fetch error, provenance mismatch, or lockfile error
- `2` — CLI usage error

## Design constraints

- Complements Bundler instead of replacing it.
- Does not hook into `bundle install`.
- Uses `Gemfile.lock` checksums as the preferred trust anchor.
- Cross-checks registry or publisher checksums when available.
- Records artifact digests only as informational data when no independent checksum exists.
- Uses configured RubyGems sources for source discovery.
- Keeps JSON output structured for CI consumers. (RubyGems fetcher noise in JSON mode is tracked separately.)
- Treats unsupported provenance as visibility data, not as a failure.

## Roadmap

- Expand release provenance checks to additional publishing workflows beyond GitHub Trusted Publishing.
- Add richer policy controls for CI enforcement.
- Track provenance adoption over time using registry audit snapshots.

## License

[MIT](./LICENSE.txt)

## Code of Conduct

Everyone interacting in the Gem::Guardian project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/kanutocd/gem-guardian/blob/main/CODE_OF_CONDUCT.md).
