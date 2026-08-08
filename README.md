# UE4SS Linux build for old-glibc game servers

Build recipe that produces a `libUE4SS.so` requiring only **GLIBC_2.28**, so it
loads on the containers game server hosts actually run.

Verified working on a live Palworld Dedicated Server `v1.0.2.101103`
(BisectHosting / `venturenodellc/palworld` container), where the published
Linux release could not load at all.

## The problem

The published [`NullPrism/RE-UE4SS-Linux`](https://github.com/NullPrism/RE-UE4SS-Linux)
`linux-v0.1.1` package requires **GLIBC_2.39** (Ubuntu 24.04). Most game server
containers are older. When the requirement is not met, the dynamic loader kills
the process during `LD_PRELOAD`, before UE4SS runs a single instruction, and
the panel shows something like:

```
[Panel]: UE4SS detected at .../ue4ss/libUE4SS.so, adding to environment..
[Panel]: Servidor marcado como offline...
[Panel]: Memory before crash: 83 MiB of 8203 MiB
```

No UE4SS banner, no log, no stack trace. It looks like a game crash and it is
not one.

For reference, on that same server:

| binary | highest glibc required |
| --- | --- |
| `PalServer-Linux-Shipping` (the game itself) | 2.17 |
| older community Linux build (`projectsphere`) | 2.28 |
| `NullPrism` `linux-v0.1.1` | **2.39** |
| this recipe | **2.28** |

## Why the official build ends up there

The requirement is not a design decision, it is a side effect. The code is
C++23 and uses `<format>`, which needs libstdc++ 13 or newer. libstdc++ 13
first appears on distros that also ship a modern glibc, so building there drags
glibc 2.39 in with it.

The fix is to decouple the two: **Ubuntu 20.04 (glibc 2.31) plus GCC 13 from
`ppa:ubuntu-toolchain-r/test`**. Modern C++ standard library, old C library.

## Use libstdc++, not libc++

An earlier attempt used `clang -stdlib=libc++`, which would have solved
`<format>` without touching glibc. It fails, and the failure is worth
recording, because libc++ 18 is missing everything this project relies on:

| what the code uses | libc++ 18 |
| --- | --- |
| `<format>` | present |
| transitive standard includes | far stricter, exposing ~60 missing `#include`s |
| `std::ctype<char16_t>` | absent (a libstdc++ extension, not standard) |
| chrono time zone database (`std::chrono::current_zone`) | absent |
| `std::time_put<char16_t>` | absent |
| `std::jthread` | behind `-fexperimental-library` |
| `std::atomic<std::shared_ptr<T>>` | **absent, and this one is fatal** |

UEPseudo stops the build itself over the last one:

```cpp
#ifndef __cpp_lib_atomic_shared_ptr
#error UEPseudo hooks require std::atomic<std::shared_ptr<T>> specialization for thread safety!
#endif
```

That is the hook dispatch path swapping callback lists without a lock while
hooks fire on the game thread. Emulating it with a mutex changes the
concurrency behaviour of the subsystem most likely to crash a server. Do not.

## Requirements

- Docker
- Access to the UE4SS source tree, including the private `UEPseudo` submodule

The `UEPseudo` submodule is private because it is generated from licensed
Unreal Engine source. Access comes from linking your GitHub account to an Epic
Games account at <https://www.unrealengine.com/ue-on-github> and accepting the
organisation invitation. **That submodule is not, and will not be,
redistributed here** - see [Licensing](#licensing).

If you only want a working binary and not the toolchain, take the one attached
to this repository's release: it is built by this recipe and needs none of the
above.

## Build

```bash
git clone https://github.com/NullPrism/RE-UE4SS-Linux.git ue4ss-src
cd ue4ss-src
git config url."https://github.com/".insteadOf git@github.com:   # submodule is pinned over SSH
git submodule update --init --recursive
git apply /path/to/this/repo/patches/*.patch
cd ..

docker build -t ue4ss-oldglibc /path/to/this/repo
mkdir -p out
docker run --rm \
    -v "$PWD/ue4ss-src:/src" \
    -v "$PWD/out:/out" \
    -v "/path/to/this/repo/build.sh:/build.sh" \
    ue4ss-oldglibc bash /build.sh
```

Output:

- `out/libUE4SS.so` - stripped and retargeted to glibc 2.28
- `out/libUE4SS.debug.so` - same build with symbols, for resolving crash addresses

Set `TARGET_GLIBC` to pick a different ceiling. 2.28 is the floor this recipe
reaches; below that, `strfromf128@GLIBC_2.26` from the Rust dependency has no
older equivalent.

## Verify before deploying

```bash
pip install pyelftools
python tools/verify.py out/libUE4SS.so --max-glibc 2.28
```

It checks the glibc ceiling, that no `libstdc++`/`libc++` is linked
dynamically (the server will not have it), and that both the modern API and the
API mods depend on are present.

## Install

Put the library where the host's launcher expects it. UE4SS resolves settings,
mods and logs relative to `libUE4SS.so`, so keeping the existing layout works:

```
Pal/Binaries/Linux/ue4ss/
├── libUE4SS.so      <- replace this file only
├── Mods/
└── UE4SS-settings.ini
```

Back up the previous binary first. On the first boot, check in order:

1. `PS scan successful` with the `GUObjectArray` / `GMalloc` / `FName`
   addresses. If this fails, the build does not recognise your game
   executable - signature resolution is version sensitive.
2. `mods directory:` pointing at your `Mods` folder.
3. Your mods' own load lines.
4. `UEHelpers.lua:35: attempt to call a nil value (global 'CreateInvalidObject')`
   should be **gone**. That error is the clearest sign an older binary is still
   in use.

Enable graphics or UI oriented mods one at a time afterwards. On the reference
server, a build that suddenly let several previously-dead mods load registered
70 hooks and aborted with `Signal=6`.

## Patches

`patches/0001-linux-libstdcxx-char16-compat.patch` touches four files in
`deps/first/Helpers`:

- `String.hpp`, `Casting.hpp` - add `<mutex>` and `<type_traits>`. Genuine
  missing includes that permissive standard libraries happened to hide.
- `SysError.cpp` - replace `std::isspace<char16_t>(c, locale)` with a direct
  ASCII comparison. The standard only requires `std::ctype` for `char` and
  `wchar_t`.
- `Time.cpp` - on Linux, derive the local offset from `localtime_r` instead of
  the chrono time zone database. The database is missing in libc++, and the
  `std::chrono::local_time` it produces has no fmt formatter for `char16_t`,
  which is this build's character type. Timestamps stay local rather than
  falling back to UTC.

## Notes on the build flags

`-D__cpp_concepts=202002L` is forced. Clang 18 reports `201907` because it has
not implemented P2113, and libstdc++ 13 uses that value to gate all of C++23,
including `<expected>`, which `glaze` needs. This is the usual workaround for
clang against libstdc++ 12/13. `-std=c++23` must be in `CMAKE_CXX_FLAGS` as
well, or CMake's own compiler check compiles at the default standard and fails
inside `<type_traits>` on the `requires` the forced macro exposes.

If this build ever misbehaves in a way the upstream one does not, that flag is
the first thing to revisit.

## Licensing

RE-UE4SS is MIT (Copyright 2022 Narknon), and so is everything in this
repository.

**UEPseudo is deliberately not included.** It is generated from licensed Unreal
Engine source, which is why every copy of it on GitHub is private, and
republishing it would breach Epic's terms. This repository ships the build
recipe and the patches, not that dependency. The compiled artifact in the
release is the practical way around the access requirement for people who just
need a working server.

## Credits

- [UE4SS-RE/RE-UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) - the project
- [NullPrism/RE-UE4SS-Linux](https://github.com/NullPrism/RE-UE4SS-Linux) - the
  Linux downstream this builds
- [tc-imba/RE-UE4SS](https://github.com/tc-imba/RE-UE4SS) - the Linux port that
  downstream is based on
- [corsix/polyfill-glibc](https://github.com/corsix/polyfill-glibc) - retargets
  the finished binary to an older glibc
