# Contributing to DevHub

Thanks for helping improve DevHub. This is a small community project, and every bug report, idea and fix helps.

## Reporting a bug

Open an issue using the **Bug report** template. The most useful reports include:
- What you did, what you expected, and what happened instead
- Your DevHub version (shown at the bottom right of the panel)
- Any red error text from Studio's **Output** window (View, then Output)
- A screenshot if the problem is visual

## Suggesting a feature

Open an issue using the **Feature request** template. Describe the problem you want solved before the solution. That helps pick the right design.

## Making changes

1. Fork the repository and create a branch for your change.
2. The whole plugin is in `src/DevHub.server.lua`. To test, copy it into your Studio **Plugins Folder** (Plugins tab, then Plugins Folder), restart Studio, and try your change.
3. Keep these in mind:
   - Roblox scripts can have at most **200 top-level `local` variables**. DevHub groups related names into tables (`K`, `Btn`, `Editor`, `Parts`, `Pure`) to stay under the limit. Add new helpers to those tables rather than creating many new top-level locals.
   - Roblox text boxes stop drawing after about 16,000 characters. Code must always go through the chunked `Editor`, never a single large TextBox.
   - Roblox text values reject very long strings. Store large data with `Parts.write` and `Parts.read`.
   - Data saved by older versions must keep loading. Don't change stored formats without a migration.
4. Test: open, edit and save a project, take a snapshot, restore it, export and import a backup, and try a script with thousands of lines.
5. Update `CHANGELOG.md` and open a pull request describing what changed and how you tested it.

## Code style

- Tabs for indentation, as in the existing file.
- Short comments that explain why, not what.
- Prefer clear names over clever code.

## Be kind

Be respectful and constructive. We're all here to make Roblox development easier.
