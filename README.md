# syncloom-apple

`SyncloomKit`, the Swift package shared by the macOS and iOS apps: UniFFI bindings, Keychain storage, sign-in flow (including security keys through a browser bridge), SwiftUI views and the File Provider extension code.

Part of [Syncloom](https://github.com/Syncloom), a self-hosted, end-to-end encrypted file sync and key/value store. Status: **public preview (0.1)**.

```bash
cd ../syncloom-core && ./build-apple.sh   # generates Frameworks/ and Sources/SyncloomKit/Generated (not committed)
swift test                                  # needs a running test stack, see syncloom-deploy
```

## Working with the other repositories

The Syncloom repositories reference each other by relative path. Clone the ones you need **side by side in one folder**, for example `syncloom-core`, `syncloom-server` and `syncloom-web` next to each other.

## License

Apache License 2.0, see [LICENSE](LICENSE).
