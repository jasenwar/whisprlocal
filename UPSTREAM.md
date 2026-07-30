# Upstream attribution

WhisprLocal is derived from OpenWhispr, originally published at
https://github.com/OpenWhispr/openwhispr under the MIT License.

The repository retains an `upstream` Git remote and the tag
`upstream-snapshot-2026-07-29` at upstream commit
`6f9c7f8c62e4b36ee287be5647f961607da55f39`.

The Electron, React, Node, cloud, account, commerce, and cross-platform
implementation was removed in favor of a purpose-built native macOS utility.
Future upstream changes are intended to be reviewed and cherry-picked
selectively.

The native media pause implementation also adapts OpenWhispr's use of
`ungive/mediaremote-adapter` v0.7.6. WhisprLocal retains only the state,
explicit Pause, and explicit Play operations, builds the framework locally,
and bundles the original BSD 3-Clause license in
`Vendor/MediaRemoteAdapter`.
