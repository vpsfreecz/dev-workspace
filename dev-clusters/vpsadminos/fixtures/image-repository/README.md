# Representative synthetic preview fixtures

The frozen `INDEX.json` contains public catalog metadata from
<https://images.vpsadminos.org/v1/INDEX.json>, fetched on
2026-11-10 at 14:10:21.949194 UTC. The exact 47,261 bytes have SHA256
`e4ff27cf6873bd18b91b8641ed2ebfb08b601122bc69c805b841f72a7b09b62b`.
No referenced image was downloaded. The catalog has 178 tuples across 16
distributions, one architecture, 169 minimal and nine impermanence images,
347 format references, 65 tag assignments and 28 distinct tags. Its default
vendor/variant aliases resolve to `vpsadminos/minimal`.

The source has no payload sizes or checksums. `image-repository-fixtures.rb`
preserves its tuple/tag/format metadata and ordering, but creates **synthetic
preview data, not OS images**. Tar payloads contain only a labelled text member;
the ZFS payloads are explicitly invalid streams. Actual synthetic sizes and
checksums appear in `synthetic.json`. They are not the real OS image sizes or
checksums. The preview's name and purpose must disclose this before downloads.

Source-only generation uses Ruby's standard library:

```sh
ruby dev-clusters/vpsadminos/lib/image-repository-fixtures.rb /absolute/new-output
```

The output is atomically published with a completion marker. An identical retry
verifies every expected byte/link; changed content or provenance refuses
replacement. Each payload is at most 4 KiB and the total is bounded to 2 MiB.
The captured source expands to 1,872 canonical/default/tag file routes.

For an existing marked demo, `ImageRepositoryDemoSeed#prepare_catalog` accepts a
coherent portable `export` directory and its expected public generation. It
prepares a complete **union**, preserving existing tuples, file IDs, metadata
and bytes. The `default` alias transition to `vpsadminos/minimal` requires
`allow_default_transition: true`; existing `demo/minimal` canonical/tag paths
remain, but the old `default` alias intentionally changes. Tuple, alias and file
ID collisions fail. The output includes a portable `manifest.json`, provenance,
completion marker and a stable `import-request.json` for the existing admin
`import-generation` operation with generation CAS. Preparation submits nothing.

Keep the input export, coherent stopped backup and current dataset for recovery.
Check the complete union and final destination path before applying the prepared
request. Do not import the raw
178-entry catalog as a replacement, call the original seed to enrich existing
state, reclaim old payloads during acceptance, or reset/recreate the dataset.
Existing runs, receipts and measurement history are not rewritten. Retrying the
same prepared request uses its original request ID/path; a new current generation
or collision requires reconciliation rather than a forced replacement.
