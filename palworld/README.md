# Deployed on a live Palworld dedicated server

This folder documents the artifact from this recipe **as it actually runs in
production**, plus the two configuration facts without which it loads and does
nothing — or crashes.

Server: Palworld Dedicated Server `v1.0.3.101283`, native Linux, BisectHosting
(`venturenodellc/palworld` container). Ten server-side Lua mods loaded, two of
them from authors who declare Linux unsupported.

The Portuguese write-up with the full measurements is in
[README.pt-BR.md](README.pt-BR.md).

## The deployed artifact

| | |
| --- | --- |
| file | `Pal/Binaries/Linux/ue4ss/libUE4SS.so` |
| size | 23,002,053 bytes |
| sha256 | `0b96231d9ad00f9de7213dea945ccfc7b9128ee80389986581a3cd7e68c41ff4` |
| highest glibc required | `libc.so.6 GLIBC_2.28` |
| release | [`glibc228-v2`](../../releases/tag/glibc228-v2) — byte-identical |

**This build is not the same bytes as `glibc228-v1`**, even though it comes from
the same sources and the two files have the identical size. The recipe is **not
reproducible**: the Rust dependency (`patternsleuth_bind`) and LTO make the
output vary between runs. Roughly 14 MB of the 23 MB differ, while the
`.gnu.version_r` ceiling, the exported symbols and the embedded strings match.

If you need the exact artifact that is known to run in production, take
`glibc228-v2` and check the sha256 above. If you rebuild from `build.sh`, expect
a different hash and verify with `tools/verify.py` instead.

## `EngineTickResolveMethod = VTable` is mandatory

Not a preference. With the default `Scan`, this server dies with `SIGSEGV`
inside the `EngineTick` hook: the address PatternSleuth finds by AOB scan
differs from the one in the vtable. The log warns about the divergence on every
boot; the setting decides which address is used.

```ini
[Hooks]
HookEngineTick = 1
EngineTickResolveMethod = VTable
```

[`UE4SS-settings.ini`](UE4SS-settings.ini) here is the exact file running on the
server — sha256
`0dc1abb5785b36682bee012d236f65ec7824df45c160ba7ebdc62e2968493299`. Besides the
setting above it also turns off hot reload, the GUI console and
`bUseUObjectArrayCache`, all of which are pointless or harmful on a headless
dedicated server.

## `ExecuteWithDelay` and `LoopAsync` never fire

The single most expensive thing we learned. On this build both are accepted, the
call returns success, **and the callback never runs.** Silently. No error, no
log line.

It took down four different mods during development, all of which "loaded fine"
and did nothing. `ExecuteInGameThreadWithDelay`, which rides on the
`EngineTick` hook above, is the only timer that works — which is also why the
`VTable` setting is not optional: every timed mod depends on that hook.

If a fresh Lua mod looks dead in this environment, check this first.

## Install

1. Copy `libUE4SS.so` (from the release) to
   `Pal/Binaries/Linux/ue4ss/`.
2. Copy `UE4SS-settings.ini` from this folder next to it.
3. Use [`run_ue4ss.sh`](run_ue4ss.sh) as the launcher — it scopes `LD_PRELOAD`
   to the game process instead of the whole container. On a panel that injects
   `LD_PRELOAD` itself (BisectHosting does), that step is already handled.
4. Mods go in `Pal/Binaries/Linux/ue4ss/Mods/<ModName>/`, each with an empty
   `enabled.txt`. Bring the server down before touching them.

`run_ue4ss.sh` and the settings file come from the upstream
`RE-UE4SS-Linux 0.1.1` package (MIT, see `../LICENSE`); only the values noted
above were changed. Source lineage is in [PROVENANCE.md](PROVENANCE.md).

## The mods running on it

Each in its own repository, all server-side, no client install:
[BreedHumans](https://github.com/prado1506/palworld-BreedHumans) ·
[PalCaptureBosses](https://github.com/prado1506/palworld-PalCaptureBosses) ·
[PalLevelScaling](https://github.com/prado1506/palworld-PalLevelScaling) ·
[PalLootScaling](https://github.com/prado1506/palworld-PalLootScaling) ·
[PalDungeonCompass](https://github.com/prado1506/palworld-PalDungeonCompass) ·
[HumansWithGender](https://github.com/prado1506/palworld-HumansWithGender) ·
[AdminCommands](https://github.com/prado1506/palworld-AdminCommands) ·
[AutoLootNearbyItems](https://github.com/prado1506/palworld-AutoLootNearbyItems) ·
[JolthogFishingShadowSync on Linux](https://github.com/prado1506/palworld-JolthogFishingShadowSync-linux)
