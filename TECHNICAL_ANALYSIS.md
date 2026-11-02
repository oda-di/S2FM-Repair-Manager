# Technical analysis

## Builds compared

- archived working build at `F:\SFM`: Source 2 changelist `8947443`;
- current Steam build: Source 2 changelist `11180900`.

The comparison was performed against the real binaries and configuration files on
this machine. The archived directory is only a reference; the final patch does not
modify it.

## MP4 regression

The old and current copies of the FFmpeg runtime libraries are byte-for-byte
identical (`libavcodec-58`, `libavformat-58`, `libavresample-4`, `libavutil-56`,
and `libswscale-5`). Both SFM binaries still contain the movie settings, MP4 name,
FFmpeg invocation and MPEG-4 bitrate strings. This rules out a missing-codec-file
explanation.

The regression is in the integration layer/UI exposed by the newer SFM and export
system. Replacing the old `sfm.dll` is unsafe because the module ABI has moved.
Replacing only `exportsystem.dll` is also unsafe: the current engine imports the
new profiler symbol
`?EnterScopeInternalBudgetFlags@?$VProfScopeHelper@$0A@$0A@@@SAP6AXXZPEBDAEAUVProfBudgetGroupCallSite@@@Z`,
which the archived DLL does not export. Both combinations were launch-tested and
then fully rolled back.

The reliable compatibility solution is therefore to keep every current binary,
use SFM's still-working lossless image-sequence/WAV render, and mux/encode it with
FFmpeg. `Convert-S2FMExportToMp4.ps1` validates the sequence and automates this as
one command. It prefers H.264 and AAC, writes `yuv420p`, pads odd dimensions, and
adds `faststart` metadata for broad player/editor compatibility.

## Lighting regression

The working build's `SceneSystem` configuration has no Sparse Shadow Tree path.
The current build adds:

```text
"SparseShadowTrees" "1"
```

The current `scenesystem.dll` also contains the new SST render/build pipeline and
its console variables; the archived DLL contains none of them. The setting's own
Valve comment describes SST as a replacement for rendering static geometry into
cascaded sun shadows. This aligns with the observed regression: the environment
sun disappears for baked/none direct-lighting maps and manually added sunlight no
longer receives correct brush/level occlusion.

Disabling SST restores the classic geometry-shadow path, but it is not sufficient
to instantiate the map sun. Current SFM also ignores `light_environment` entities
whose `directlight` mode is baked/none. A binary comparison of the actual
`default_ents.vents_c` entity lump found `directlight = 1` on both archived and
current `de_overpass`. The working current `de_cache` instead uses
`directlight = 3` (stationary).

An entity-lump experiment changed only `light_environment.directlight` to `3`
and passed a complete semantic round-trip: all 754 Overpass entities remained
identical except that value. A loose `default_ents.vents_c` was ignored because
the map owns its embedded entity lump through `de_overpass.vpk`.

Legacy 3D-skybox maps require a second compatibility branch. Investigation of
`de_nuke` showed that `skybox_reference` loads
`maps/prefabs/de_nuke/de_nuke_skybox02.vmap`, which is packaged as a separate VPK.
That VPK contains its own `light_environment` with `directlight = 1`. Patching only
the main map therefore lights the playable world while leaving the skybox on the
ignored baked mode, producing the exact rectangular boundary seen in SFM.

The installer now resolves every `skybox_reference`, locates its VPK and patches
both the main map and referenced skybox lights to fully dynamic mode. Maps without
a legacy 3D skybox continue to use the verified stationary entity-lump override.

The entity helper accepts existing modes 1, 2, and 3, normalizes all environment
lights to the selected runtime mode, and verifies the serialized result. This is
required for maps such as `cs_shelter`, whose main light already uses mode 3 while
its separate skybox requires the combined dynamic path.

Official rotation maps can keep bulk resources in split packages below
`game\csgo_community_addons\<map>`. Their referenced skybox VPK may itself be nested
inside that package. The installer resolves and extracts the nested VPK for the
entity-only patch, records the containing package and entry hashes, and leaves all
other resources in place. At launch, the selected split VPK is added as a managed
`Game` search path before the engine starts, so the resources are mounted before
SFM opens the requested session. The live `gameinfo.gi` hash and rollback manifest
are updated together, and the managed entry is replaced or removed on the next
launch. A process-scoped cleanup helper removes the entry after SFM exits unless a
newer launch has already selected another community package.

The final compatibility path combines the global SST gate with a complete
addon-local map VPK. `S2FMVpkPatcher` replaces only the entity lump in the main map
and, when present, each referenced skybox VPK. It verifies that the entry count and
all unrelated CRC/length pairs remain unchanged, reads each replacement back, and
validates every file checksum. Original VPKs under `game\csgo\maps` are never
modified. The addon search path is mounted ahead of base CS2 in tools mode, so SFM
resolves the compatible packages first.

`Repair-S2FMSessionLight.ps1` is retained as an optional per-session tool for
custom directional lights. It updates the named `DmeGameDirectionalLight`, its
intensity expression/control graph, and its color packing graph; performs a
binary DMX round-trip; verifies the result; and atomically replaces the session
while retaining the exact saved original.

## Safety model

- CS2/SFM must be closed before install or rollback.
- The installer requires exactly one known enabled setting.
- The original `gameinfo.gi` is copied before modification.
- SHA-256 hashes are recorded in a JSON manifest.
- Rollback refuses to overwrite a later Steam update or user edit.
- No files from the archived game build are redistributed or installed.
