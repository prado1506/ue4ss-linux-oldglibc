# Build environment for a UE4SS Linux artifact that loads on old-glibc game
# server containers.
#
# Why Ubuntu 20.04: it provides glibc 2.31, and the toolchain PPA provides GCC
# 13 on top of it. That combination is the whole trick - the C++ standard
# library and the C library are decoupled, so the artifact gets modern C++
# without inheriting a modern glibc requirement.
#
# Why libstdc++ and not libc++: UEPseudo refuses to compile without
# std::atomic<std::shared_ptr<T>>, which libc++ 18 does not implement. The same
# library also supplies <format>, the chrono time zone database, std::ctype and
# std::time_put for char16_t, and std::jthread, every one of which libc++ 18
# lacks or gates behind an experimental flag.
FROM ubuntu:20.04

ARG DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends \
        ca-certificates curl git gnupg ninja-build pkg-config \
        python3-pip software-properties-common xz-utils \
    && add-apt-repository -y ppa:ubuntu-toolchain-r/test \
    && apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends gcc-13 g++-13 libstdc++-13-dev \
    && curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/llvm.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/llvm.gpg] http://apt.llvm.org/focal/ llvm-toolchain-focal-18 main" \
        > /etc/apt/sources.list.d/llvm18.list \
    && apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends clang-18 lld-18 \
    && rm -rf /var/lib/apt/lists/*

# Ubuntu 20.04 ships CMake 3.16; the project requires 3.22 or newer.
RUN pip3 install --quiet --no-cache-dir "cmake>=3.28"

# patternsleuth uses edition 2024 and `let` chains, so Cargo 1.88 is the floor.
# Rust targets glibc 2.17 for x86_64-unknown-linux-gnu, so a modern toolchain
# does not raise the requirement of the artifact.
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo
ENV PATH=/opt/cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
        | sh -s -- -y --profile minimal --default-toolchain 1.88.0

WORKDIR /src
