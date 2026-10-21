# Tokenline

Design tokens for Flutter, synced with Figma.

Tokenline keeps one set of [DTCG](https://www.designtokens.org/) token files in
your repo, turns them into typed Dart constants, and keeps them in step with
Figma variables in both directions:

```
Figma variables ──(plugin Export)──► tokenline pull ──► design_tokens/*.json ──► lib/…/*.g.dart
        ▲                                                       │
        └────────────(plugin Import)◄── tokenline push ◄────────┘
```

- **One pull.** `dart run tokenline pull` reads Figma, updates the token files and
  regenerates Dart. Git stays the release gate: review the diff, commit.
- **Works on every Figma plan.** The Tokenline plugin exports variables (with their
  links and ids) into the Figma file; the pull reads that with one REST request.
  No Enterprise-only Variables API needed, and no file-read quota burned per token.
- **Links survive.** `text/primary → neutral/900` stays a link in JSON
  (`{color.neutral.900}`), not a copied hex.
- **Safe by default.** Push never deletes unless you ask (`--prune`). Pull refuses
  tokens that were removed or renamed in Figma without being deprecated first,
  because code that uses them would stop compiling.
- **The same rules everywhere.** The plugin's Lint and `tokenline lint` share one
  rule set, so designers see problems while designing, not in code review.

## Install

```yaml
# pubspec.yaml
dev_dependencies:
  tokenline:
    git:
      url: https://github.com/alfatihtalab/tokenline
      ref: v0.1.0
```

The generated code needs only Flutter; tokenline itself is a dev dependency.

## Quick start

```bash
dart run tokenline init --prefix App --file-key <figma file key>
```

That writes `tokenline.yaml`, starter tokens in `design_tokens/`, generates
`lib/design_system/foundations/generated/app_*.g.dart`, and adds
`.tokenline.env` to `.gitignore`. Then:

1. Put `FIGMA_ACCESS_TOKEN=figd_…` in `.tokenline.env` (Figma → Settings →
   Security → Personal access tokens, file read scope). Never commit it, and never
   put it in the app's own `.env`, which Flutter apps often ship inside the binary.
2. `dart run tokenline plugin` — writes the Figma plugin to `figma_plugin/`. In
   Figma: Plugins → Development → Import plugin from manifest.
3. `dart run tokenline push` — writes `design_tokens/figma-sync/push.figma.json`.
   In Figma open Tokenline → **Import push file…** to create the variables.
4. Designers edit, run **Lint**, publish, and click **Export**.
5. `dart run tokenline pull` — updates the token files and the Dart code.

## Commands

| Command | What it does |
| --- | --- |
| `init` | Create `tokenline.yaml` and starter tokens |
| `validate` | Check types, values, links, cycles, themes and Dart names |
| `generate` | Regenerate the Dart classes (`--check`: exit 2 if stale) |
| `check` | CI gate: valid tokens and current generated files |
| `pull` | Figma → token files → Dart. `--check` reports only (exit 2 on drift), `--from-file export.json` reads a plugin export, `--allow-removals` accepts breaking removals |
| `push` | Token files → files Figma can apply. `--prune` also deletes extras |
| `lint` | Run the rules on Figma (or `--from-file`) |
| `plugin` | Write the Figma plugin (Lint, Fix, Export, Import) |
| `icons` | Pull icon components as SVG string constants |

Global options: `-C <dir>` runs in another project, `--config <file>` points at
another `tokenline.yaml`.

## `tokenline.yaml`

```yaml
name: acme-design-tokens   # shown in generated headers
version: 1.0.0

tokens:
  dir: design_tokens
  primitives: [primitives/*.tokens.json]   # * matches inside one folder
  modes:                                   # one semantic file per theme
    light: semantic/light.tokens.json
    dark: semantic/dark.tokens.json
  components: [components/*.tokens.json]   # optional

flutter:
  output_dir: lib/design_system/foundations/generated
  class_prefix: App          # AppColors, AppSpacing, …
  class_names:               # optional: token group -> class
    opacity: AppOpacities
  docs:                      # optional: class -> doc comment
    AppFonts: Typography foundations.
  # run_command: dart run tool/old_generator.dart   # header text, for side-by-side migrations

figma:
  file_key: AbCdEf123        # figma.com/design/<file_key>/…
  source: plugin             # plugin | variables-api | sync-frame
  name_case: kebab           # font/line-height/tight (or camel)
  collections:
    primitives: Primitives
    semantic: Semantic
    components: Component
  modes: { light: Light, dark: Dark }   # default: capitalised theme names
  primitive_mode: Base
  hide_primitives: true      # keep primitives out of pickers and the library
  code_syntax:               # Dev Mode code field; false turns it off
    primitives: "{class}.{name}"
    semantic: "{name}"
  env_file: .tokenline.env

icons:                       # optional
  manifest: design_tokens/icons/icons-manifest.json   # {"icons": {"name": "<node id>"}}
  class_name: AppIcons

lint:
  groups: [breakpoint]       # extra allowed first groups for number primitives
```

Unknown keys are errors, so a typo never silently does nothing.

## How Figma is read

| `figma.source` | How | Plans | Sees links, ids, descriptions |
| --- | --- | --- | --- |
| `plugin` (default) | The plugin's Export stores the variables in the file; pull reads them with one request, or use `pull --from-file` with no API call at all | all | yes |
| `variables-api` | `GET /v1/files/:key/variables/local` | Enterprise | yes |
| `sync-frame` | A frame of rectangles bound to variables (legacy) | all | values only |

Figma caps file reads for View and Collab seats, and for files on the Starter plan,
at 6 a month. On those, export from the plugin and pull with `--from-file`.

## Generated code

Primitives, one class per theme for semantic colors, component colors per theme,
and a class per number group — for example with `class_prefix: App`:

```dart
AppColors.neutral900          // primitive
AppColorsLight.textPrimary    // semantic, per theme
AppSpacing.space16
AppRadius.md / AppRadius.mdBr // double and BorderRadius
AppFonts.primary / AppFonts.semibold
AppMotion.fast                // Duration
```

Deprecated tokens (`"$deprecated": "Use color.text.primary instead."`) become
`@Deprecated` constants, so the analyzer tells developers what to switch to.
Output is formatted with the project's own Dart language version and page width.

## Rules for designers

The plugin and `tokenline lint` check: name format, allowed groups, Dart name
clashes and reserved words, primitives hold values only, semantic tokens link to
primitives, component colors link to semantic tokens, every theme has a value,
drafts (`_draft/…`) never sync, and deprecations point at a token that exists.
The plugin also flags typed colors and primitives used directly on components.
`validate` and `push` apply the level rules to the token files too, so nothing
reaches Figma that its lint would reject.

## CI

```yaml
- run: dart run tokenline check
- run: dart run tokenline lint --from-file design_tokens/figma-sync/figma-snapshot.json
```

`pull` writes `figma-snapshot.json` (what Figma had) and `figma-ids.json` (how
pull tells a rename from a removal). Commit both with the token files.

## License

MIT
