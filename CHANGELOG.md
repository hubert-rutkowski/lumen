# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [1.1.0] - 2026-11-13

### Added

- Small arrows next to each band value change it one percent per click; holding an arrow repeats.

### Changed

- Moving a band no longer resets the tone sliders. The tone adjustment stays in place and the band stores the value needed to reach the chosen brightness.

## [1.0.1] - 2026-11-13

### Fixed

- Tone values showed 0 after startup when the loaded profile had a tone adjustment.

## [1.0.0] - 2026-11-13

### Added

- Ten-band brightness curve driven by the ambient light sensor, with a live marker for the current reading.
- Tone controls: exposure, contrast, highlights and shadows.
- Named profiles with a default profile, rename, delete and undo.
- Light and brightness readouts in the title bar and a three-minute history in the side panel.
- Five transition speeds with filtering of brief light changes.
- Tray icon, start at sign-in, dark and light theme.
- Recovery from a damaged settings file with a backup copy.
- Built-in self-test and dry-run mode.

[1.1.0]: https://github.com/hubert-rutkowski/lumen/releases/tag/v1.1.0
[1.0.1]: https://github.com/hubert-rutkowski/lumen/releases/tag/v1.0.1
[1.0.0]: https://github.com/hubert-rutkowski/lumen/releases/tag/v1.0.0
