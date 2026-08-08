#!/usr/bin/env python3
"""Check that a libUE4SS.so will load on the target server and exposes the API
its mods need.

    pip install pyelftools
    python tools/verify.py out/libUE4SS.so [--max-glibc 2.28]

The glibc check is the one that matters most: when the requirement is higher
than the host provides, the dynamic loader kills the game server process before
UE4SS prints a single line, which looks like an unexplained instant crash.
"""
import argparse
import sys

from elftools.elf.elffile import ELFFile

# Present in a current UE4SS, absent from older Linux builds. Their absence is
# what breaks UEHelpers-based mods and hooks on functions with delegate
# parameters.
MODERN_SYMBOLS = [
    b"CreateInvalidObject",
    b"push_delegateproperty",
    b"ExecuteInGameThreadWithDelay",
    b"LoopInGameThreadWithDelay",
    b"FUtf8String",
]

# The Lua API surface mods rely on. A build missing any of these is broken even
# if it loads.
REQUIRED_SYMBOLS = [
    b"RegisterHook",
    b"UnregisterHook",
    b"FindAllOf",
    b"FindFirstOf",
    b"StaticFindObject",
    b"LoopAsync",
    b"ExecuteWithDelay",
    b"NotifyOnNewObject",
    b"RemoteUnrealParam",
]


def version_key(version: str) -> tuple:
    return tuple(int(part) for part in version.replace("GLIBC_", "").split("."))


def glibc_requirements(path: str) -> set:
    with open(path, "rb") as handle:
        elf = ELFFile(handle)
        section = elf.get_section_by_name(".gnu.version_r")
        if section is None:
            return set()
        found = set()
        for verneed, auxiliaries in section.iter_versions():
            for auxiliary in auxiliaries:
                if auxiliary.name.startswith("GLIBC_"):
                    found.add(auxiliary.name)
        return found


def needed_libraries(path: str) -> list:
    with open(path, "rb") as handle:
        elf = ELFFile(handle)
        dynamic = elf.get_section_by_name(".dynamic")
        return [tag.needed for tag in dynamic.iter_tags("DT_NEEDED")]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("library")
    parser.add_argument("--max-glibc", default="2.28")
    args = parser.parse_args()

    blob = open(args.library, "rb").read()
    failures = []

    required = glibc_requirements(args.library)
    highest = max(required, key=version_key) if required else "GLIBC_0.0"
    ceiling = "GLIBC_" + args.max_glibc
    if version_key(highest) > version_key(ceiling):
        failures.append(f"requires {highest}, above the {ceiling} ceiling")
    print(f"glibc required : {highest} (ceiling {ceiling})")

    needed = needed_libraries(args.library)
    print(f"NEEDED         : {', '.join(needed)}")
    for library in needed:
        if "libstdc++" in library or "libc++" in library:
            failures.append(f"links {library} dynamically; the server will not have it")

    print("\nmodern API (absent from older Linux builds):")
    for symbol in MODERN_SYMBOLS:
        present = symbol in blob
        print(f"  {'ok ' if present else 'MISSING'} {symbol.decode()}")
        if not present:
            failures.append(f"missing {symbol.decode()}")

    print("\nAPI the mods use:")
    for symbol in REQUIRED_SYMBOLS:
        present = symbol in blob
        print(f"  {'ok ' if present else 'MISSING'} {symbol.decode()}")
        if not present:
            failures.append(f"missing {symbol.decode()}")

    if failures:
        print("\nFAILED:")
        for failure in failures:
            print(f"  - {failure}")
        return 1

    print("\nAll checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
