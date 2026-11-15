# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [1.1.2] - 2026-11-15

### Changed

- The transition speed is a percentage from 10% to 1000%, set with the slider or one percent at a time with the arrows. At 100% the brightness moves 20 points per second, and the pace is the same in both directions. Speeds saved by older versions are converted.
- Lumen uses less power in the background: it reads the sensor once a second, checks the screen brightness every five seconds and wakes less often while its window is hidden.

## [1.1.1] - 2026-11-15

### Fixed

- The brightness followed the ambient light only at startup. With the automatic brightness of Windows turned off, the sensor kept returning its first reading; Lumen now listens to the sensor so that readings keep arriving.
- A false reading of 0 lx right after the sensor starts is no longer used.

### Changed

- The slow and very slow speeds are much slower: one percent every 0.4 s and every second.

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

[1.1.2]: https://github.com/hubert-rutkowski/lumen/releases/tag/v1.1.2
[1.1.1]: https://github.com/hubert-rutkowski/lumen/releases/tag/v1.1.1
[1.1.0]: https://github.com/hubert-rutkowski/lumen/releases/tag/v1.1.0
[1.0.1]: https://github.com/hubert-rutkowski/lumen/releases/tag/v1.0.1
[1.0.0]: https://github.com/hubert-rutkowski/lumen/releases/tag/v1.0.0
