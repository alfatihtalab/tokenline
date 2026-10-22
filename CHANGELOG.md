## 0.1.0-dev

- `tokenline sync`: one command plus one click in the plugin syncs both ways
  through a local connection (no API token, no rate limits). Three-way merge
  against the last sync; asks only when both sides changed a token.
- Three visible commands: `setup`, `sync`, `check`. The others are hidden.
- Plugin: Sync button that runs on open; Export/Import moved under "Without
  tokenline sync"; the delete option is a checkbox instead of a pop-up.

- First version, extracted from the Rezme app's token scripts.
- `tokenline.yaml` config; DTCG token files; generated Dart classes with a layout
  that adapts to the token groups a project has.
- Figma sync: plugin export (any plan), Variables API (Enterprise) and the legacy
  sync frame. Pull keeps links, adds and deprecates tokens, refuses undeprecated
  removals and spots renames by variable id.
- Push writes a plugin import file and use_figma scripts (split under 50,000
  characters); deletes only with `--prune`.
- The Tokenline Figma plugin: Lint, Fix, Export, Import.
- Lint rules shared by the CLI and the plugin.
- Icon pull: Figma components to SVG string constants.
- `validate` and `push` enforce the level rules on the token files.
