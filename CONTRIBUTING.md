# Contributing to Islandly

Thanks for helping make Islandly better! Bug reports, fixes and ideas are all welcome.

## Found a bug?
1. Check [existing issues](../../issues) first.
2. Open a **Bug report** and include your macOS version, Mac model (notch or not, Apple Silicon or Intel),
   what you did, what you expected, and what happened. Screenshots or a short screen recording help a lot.

## Have an idea?
Open a **Feature request** describing the problem it solves. For bigger changes, please discuss in an issue
before writing code so we can agree on the approach.

## Sending a pull request
1. Fork the repo and create a branch: `git checkout -b fix/short-description`
2. Build and run it:
   ```bash
   ARCHS=arm64 ./build.sh      # fast single-architecture build (drop ARCHS for universal)
   open build/Islandly.app
   ```
   Tip: create the `Islandly Dev` signing certificate (see the README) so macOS doesn't reset permissions on every build.
3. Keep changes focused — one fix or feature per pull request.
4. Match the existing style: SwiftUI views in `Views.swift` / feature files, models as `ObservableObject`s,
   short doc comments on anything non-obvious.
5. Check that idle CPU stays under ~1% (Activity Monitor) — Islandly lives on screen all day.
6. Open the pull request with a clear description and screenshots or a GIF for UI changes.

## Guidelines
- **Privacy first:** everything stays on-device. No analytics, no network calls beyond what a feature strictly needs.
- **Battery matters:** prefer event-driven code over polling, and slow down anything that runs while the island is closed.
- Be kind and constructive in issues and reviews.

## Terms
Islandly is source-available, not open source — see [LICENSE](LICENSE). By submitting a contribution you agree it can
be included and distributed as part of Islandly under those terms.
