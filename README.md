# DevHub

**A GitHub-style project workspace for Roblox scripters, built right into Roblox Studio.**

Write code, save it as a project, take snapshots (like commits), compare changes, and reuse your code in any game, without leaving Studio.

> DevHub is an independent open-source project. It is not affiliated with, endorsed by, or sponsored by GitHub or Roblox.

<!-- Add a screenshot here after uploading it to docs/images, for example:
![DevHub home screen](docs/images/home.png)
-->

## Features

- **Projects:** keep a personal library of scripts and snippets. Search, sort (recent, name, snapshot count), duplicate, rename and delete.
- **Snapshots (like commits):** save a restore point with a description whenever you reach a good state.
- **History and Diff:** browse snapshots, see a line-by-line diff (red and green) against your current code, restore one, or delete it.
- **Pull and Push:** pull the code of a script selected in the Explorer into the editor. Push your code back by replacing or appending to scripts, or create a new Script, LocalScript or ModuleScript.
- **Import:** select several scripts in the Explorer and turn them into projects in one click.
- **Code editor for long scripts:** line numbers, undo and redo, Ctrl+S to save, and a live line and column display. Scripts of any length display in full.
- **Safe by design:** unsaved-change warnings, an automatic recovery draft if Studio closes unexpectedly, and a last-known-good backup before every save.
- **Storage you choose:**
  - *Plugin settings* is private to you and shared across every place on your computer.
  - *This place* saves inside the place file (`ServerStorage > DevHubData`), so teammates who open the place can see it.
- **Backup:** export all projects into the place (`ServerStorage > DevHubBackup`) and import them back. Large libraries are split into parts automatically.
- **Responsive UI:** the toolbar wraps instead of clipping in a narrow dock.

## Installation

### Option 1: Download the plugin file (recommended)
1. Go to the [Releases](../../releases) page and download the latest `DevHub.rbxm` (or `DevHub.rbxmx`).
2. In Roblox Studio, open the **Plugins** tab and click **Plugins Folder**.
3. Move the downloaded file into that folder.
4. Restart Roblox Studio. A **DevHub** button appears in the Plugins tab.

### Option 2: From source
1. Download `src/DevHub.server.lua` from this repository.
2. Put it in your Studio **Plugins Folder** (Plugins tab, then Plugins Folder).
3. Restart Roblox Studio.

> Install only one copy of DevHub at a time. Two versions in the Plugins Folder will conflict.

## Quick start

1. Click **DevHub** in the Plugins tab to open the panel.
2. Click **+ New** to create a project, or select scripts in the Explorer and click **Import**.
3. Click a project to open it. Edit your code and press **Save** (or Ctrl+S).
4. Click **Snapshot** to save a restore point. Open **History** to compare or restore.
5. Use **Pull** and **Push** to move code between a project and scripts in your game.

## Tips

- Snapshots are separate from Save. Save updates the project's current code, and Snapshot records a version you can return to.
- Restoring a snapshot never saves by itself. Press Save to keep it, or Undo to go back.
- Push sends your editor text, including edits you haven't saved yet.
- Export a backup before big changes or before moving to a new computer.

## Known limitations

- A project holds the code of **one script**, not a folder of scripts (see the roadmap).
- Ctrl+A selects text within one section of the editor only. Very long scripts are shown as several stacked sections, so you can't drag-select across the boundary between two sections.
- There is no online sync. Data lives in your plugin settings or inside the place file.
- No syntax highlighting yet. For heavy editing, use Studio's own script editor and use Pull and Push to move code in and out.

## Roadmap

- Projects that hold multiple scripts and mirror the Explorer hierarchy
- Compare any two snapshots
- Search inside all saved code
- Branches with a manual merge screen
- Shareable single-file export and import

Ideas and votes are welcome. Please open an issue.

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) first. Bug reports and feature requests use the issue templates.

## License

Released under the [MIT License](LICENSE).
