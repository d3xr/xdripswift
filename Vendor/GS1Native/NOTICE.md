# Provenance

The upstream algorithm and public replay fixture are from **ctqvva/JugglucoNG**,
commit `11e6e29db7d9055c8fd2e96261812e16f2095f3d`, read on 2026-10-31.
The repository includes GNU GPL version 3 in `LICENSE.txt`; an unchanged copy
is retained in `upstream/LICENSE.txt`. Upstream source files and their SHA-256
hashes are recorded in `evidence/source-manifest.json`.

The exact V1.1.5G sources first appear in commit
`23d21eb7aa195685fd5c794e9bd06fa0da9213e4` (2026-07-09, author ctqvva,
“Sibionics koltin v4”), followed by parity commit
`90a452ee5b1ca72d2b1dc030154d40034083033b` (2026-07-10).
Their own documentation describes a managed port of a recovered vendor
pipeline. This is community reverse engineering, not an official Sibionics SDK.
The public repository's license statement is evidence of its publication terms,
not an independently verified chain of rights in the manufacturer's algorithm.

Local changes preserve every algorithm expression. Only Java I/O imports,
System.arraycopy, Integer.compareUnsigned and unsigned Long decimal formatting
were replaced with equivalent common Kotlin implementations. The two required
observation data classes were extracted unchanged from SibionicsAlgorithm.kt.
Local compatibility, façade, build and replay files use the same GPL-3.0 terms.

No personal health data were collected or transmitted. Tests consume only the
already public upstream CSV. No upstream project script, Gradle build, workflow
or CI job was executed. Official compiler launchers are separately downloaded,
hashed and inspected before use.
