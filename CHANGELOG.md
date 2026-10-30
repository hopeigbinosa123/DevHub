# Changelog

All notable changes to DevHub are listed here.

## [5.1] - 2026-10-25

### Fixed
- Long scripts were cut off in the editor after roughly 16,000 characters (about 500 lines). The editor now shows code in stacked sections with continuous line numbers, so scripts of any length display in full.
- Exporting a backup failed for larger libraries ("Unable to assign property Value. Provided string length..."). Backups and "This place" storage are now split into several parts and verified after writing.

### Changed
- Importing a backup now explains what is wrong if the backup is missing, incomplete or damaged.
- Arrow keys, Backspace and Delete work across the boundaries between editor sections.

## [5.0] - 2026-10-24

### Added
- Redesigned interface where every button is visible and clickable.
- A single dialog system for rename, create, confirm and choice prompts.
- History view with line-by-line Diff, Restore and Delete for snapshots.
- Pull from and Push to scripts in Studio (Script, LocalScript and ModuleScript).
- Import of several selected scripts as projects in one click.
- Project search, sorting, duplicate and rename.
- Settings for storage location, save-on-close prompt, copying between storages, and backup export and import.
- Responsive toolbar that wraps in narrow docks.

### Compatibility
- Reads data saved by v4.x.

## [4.2] and earlier
- Initial versions: project list, code editor, snapshots, recovery drafts and plugin or place storage.
