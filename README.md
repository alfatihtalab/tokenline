# Tokenline

Design tokens for Flutter, synced with Figma.

Your tokens live in [DTCG](https://www.designtokens.org/) JSON files in the
repo. Tokenline turns them into typed Dart constants and keeps them in step
with Figma variables, in both directions, with one command and one click.

## Three commands

```bash
dart run tokenline setup    # once: config, starter tokens, the Figma plugin
dart run tokenline sync     # every time: Figma <-> code, Dart regenerated
dart run tokenline check    # CI: fails if something is out of date
```

## Install

```yaml
# pubspec.yaml
dev_dependencies:
  tokenline:
    git:
      url: https://github.com/alfatihtalab/tokenline.git
      ref: main
```

The generated code needs only Flutter; tokenline itself is a dev dependency.

## Set up (once)

1. `dart run tokenline setup` — writes `tokenline.yaml`, starter tokens in
   `design_tokens/`, the generated Dart classes, and the plugin in
   `figma_plugin/`. Safe to run again: it keeps your files and refreshes the
   plugin.
2. In the **Figma desktop app**, in **Design mode** (not Dev Mode): main menu →
   Plugins → Development → **Import plugin from manifest…** →
   `figma_plugin/manifest.json`. Once per computer.

## Sync (every time)

1. `dart run tokenline sync`
2. In Figma, open the Tokenline plugin (⌥⌘P runs it again). It syncs right away.

That's it. Both sides end up identical, the Dart code is regenerated, and the
terminal tells you what moved. Review the git diff and commit.

**How sync decides.** It remembers the state after the last sync
(`design_tokens/figma-sync/figma-snapshot.json` — commit it). A change made
only in Figma goes to the code; a change made only in code goes to Figma; a
token deleted in code is deleted in Figma. When both sides changed the same
token differently, sync asks you in the terminal which to keep (or pass
`--prefer figma|code`). On the first sync every disagreement is asked.

**Safety.** A token deleted or renamed in Figma without being deprecated first
stops the sync, because code that uses it would no longer compile. Mark it
`@deprecated → new/name` in Figma instead (or pass `--allow-removals`).
Figma rule errors (the plugin's **Lint** shows them) also stop the sync.

No Figma API token is needed for sync: the plugin talks directly to
`tokenline sync` on your computer (`http://localhost:4747`).

## Using the classes

Tokenline generates constants, not a `ThemeData`; map them once:

```dart
ThemeData buildTheme(Brightness b) {
  final isLight = b == Brightness.light;
  return ThemeData(
    brightness: b,
    scaffoldBackgroundColor:
        isLight ? AppColorsLight.backgroundBase : AppColorsDark.backgroundBase,
    colorScheme: ColorScheme.fromSeed(seedColor: AppColors.brand500, brightness: b)
        .copyWith(primary: isLight ? AppColorsLight.actionPrimary : AppColorsDark.actionPrimary),
  );
}
```

Elsewhere: `AppSpacing.space16`, `AppRadius.mdBr`, `AppFonts.primary`,
`AppMotion.fast`. Deprecated tokens become `@Deprecated` constants.

## Advanced

These still work but are hidden from `--help`; you rarely need them.

| Command | Use |
| --- | --- |
| `pull` / `pull --check` | Figma → code over Figma's REST API (CI, scheduled drift checks). Needs `FIGMA_ACCESS_TOKEN` in `.tokenline.env` |
| `push` | Write a file for the plugin's **Import push file…** (when `sync` can't run) |
| `lint` | Run the rules on a Figma export |
| `generate`, `validate` | Regenerate Dart / check token files only |
| `icons` | Pull icon components as SVG constants (REST API) |
| `plugin` | Rewrite `figma_plugin/` only |

REST reads are capped by Figma at 6 a month for View/Collab seats and files on
the Starter plan; `sync` uses no API calls.

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
