# Zstandard decoder

Vendored from the official Zstandard v1.5.7 release, using the BSD license
in `Resources/ThirdParty/zstd-LICENSE` (also shipped inside the app bundle).

Source: https://github.com/facebook/zstd/releases/tag/v1.5.7

The release archive was verified against the upstream `.sha256` asset:
`eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3`.

`zstddeclib.c` is generated without edits by upstream's
`build/single_file_libs/create_single_file_decoder.sh`. Its SHA-256 is
`5eb38abe0a7eea13674b312a006df72002d4192f0f0b4d09e6f03fb927a1f3d0`.
The two public headers are unmodified copies from `lib/`.

Only decompression is linked. No external executables, dynamic Homebrew
libraries, network downloads or extracted rollout files are needed at runtime.
