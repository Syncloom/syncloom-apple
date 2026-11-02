# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [semantic versioning](https://semver.org/). Syncloom is a public preview until 1.0.

## [Unreleased]

### Added
- Dropping or uploading whole folders: the tree is uploaded recursively, empty folders are kept, symlinks and `.DS_Store` are skipped, and a folder whose name already exists is merged into. One failing item no longer stops the rest.
- Names that the core rejects (for example `:` or `/` from a Finder date such as "19/10/26") are renamed with `_` on upload, and the dialog lists what was changed.

### Fixed
- Error dialogs cut the text at the first quotation mark of a file name; they now show the full reason.
- The storage meter showed "Zero KB used" until the next sign-in. It now follows server changes. Without a quota it shows no bar.

## [0.1.0] - 2026-11-02

First public preview.

### Added
- Swift package SyncloomKit shared by macOS and iOS: UniFFI bindings, Keychain storage, sign-in flow, SwiftUI views, File Provider extension code, browser bridge for security keys.

### Fixed
- File Provider change enumeration no longer treats every lookup failure as a deletion.
- Unregistering the Finder location preserves unsynced edits on macOS.

### Known limits
- iOS: only built and run in the simulator.
