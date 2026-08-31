# Zapper

macOS menu bar remote for LG webOS TVs. Finds the TV over Bonjour, drives it
over SSAP — no HomeKit, no LG account.

## Features

- **Search everything from one bar** (auto-focused — just start typing):
  - `123` → tunes to channel 123; channel names work too
  - `net` → suggests Netflix and other apps/inputs
  - `friends` → shows which of your streaming apps have it (Netflix *and*
    HBO Max, say); Enter plays it — apps resume where you left off
  - `friends s1 e4` → plays that episode, preferring the service that can
    deep-link to it directly
  - anything else → hand the query to Spotify's or YouTube's own search on
    the TV
- Quick-launch tiles for your top three apps (right-click to change)
- Full D-pad, OK, back/home, volume with slider, channel rocker + number pad,
  input switching, power (on via Wake-on-LAN — enable Quick Start+ on the TV)

## Install

```sh
./build.sh
cp -r build/Zapper.app /Applications && open /Applications/Zapper.app
```

First run: allow **Local Network** access, then accept the pairing prompt on
the TV (once). Pairing and the TV's pinned certificate live in
`~/Library/Application Support/Zapper/devices.json`.

## CLI

`zapperctl` drives the same core headlessly:

```sh
zapperctl discover
zapperctl key 192.168.1.212 ok
zapperctl channel 192.168.1.212 124
zapperctl launch 192.168.1.212 netflix [deep-link-url]
zapperctl find "friends"          # streaming availability search
zapperctl findep "friends" 1 4    # per-episode deep links
```

## Notes

- Content search uses JustWatch's public endpoint (no key, region from your
  macOS locale). If it breaks, channel/app search still works.
- `Sources/ZapperKit` is the device-agnostic core; `RemoteDevice` is the seam
  for adding non-LG devices.
