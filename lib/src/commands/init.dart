import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import 'base.dart';
import 'plugin.dart';

/// `tokenline setup`: everything a project needs, safe to run again (it
/// keeps existing files and refreshes the Figma plugin).
class SetupCommand extends TokenlineCommand {
  SetupCommand() {
    argParser
      ..addOption('prefix',
          defaultsTo: 'App', help: 'Prefix for generated classes (AppColors).')
      ..addOption('file-key',
          help: 'Figma file key (only needed for CI pulls and icons).')
      ..addFlag('force',
          negatable: false, help: 'Overwrite an existing tokenline.yaml.');
  }

  @override
  String get name => 'setup';

  @override
  String get description =>
      'Set up tokenline in this project (config, starter tokens, Figma plugin).';

  @override
  int run() {
    final root = p.absolute(globalResults?['root'] as String? ?? '.');
    final configFile = File(p.join(root, configFileName));
    if (configFile.existsSync() && !(argResults!['force'] as bool)) {
      info('$configFileName exists — kept');
    } else {
      configFile.writeAsStringSync(configTemplate(
          prefix: argResults!['prefix'] as String,
          fileKey: argResults!['file-key'] as String?));
      info('created $configFileName');
    }

    final tokensDir = Directory(p.join(root, config.tokens.dir));
    if (tokensDir.existsSync()) {
      info('${config.tokens.dir}/ exists — kept');
    } else {
      starterTokens.forEach((rel, json) {
        File(p.join(tokensDir.path, rel))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(
              '${const JsonEncoder.withIndent('  ').convert(json)}\n');
      });
      info('created starter tokens in ${config.tokens.dir}/');
    }

    final gitignore = File(p.join(root, '.gitignore'));
    final lines =
        gitignore.existsSync() ? gitignore.readAsLinesSync() : <String>[];
    if (!lines.contains('.tokenline.env')) {
      gitignore.writeAsStringSync(
          '${lines.isEmpty || lines.last.isEmpty ? '' : '\n'}'
          '# Figma token for tokenline (never commit it)\n.tokenline.env\n',
          mode: FileMode.append);
    }

    final manifest = writePlugin(p.join(root, 'figma_plugin'));
    final changed = regenerate(check: false);
    info(
        '${changed.isEmpty ? 'Dart files are current' : 'generated ${changed.length} Dart file(s)'}\n'
        '\nReady. Next:\n'
        '  1. Once per computer, in the Figma desktop app (Design mode):\n'
        '     main menu → Plugins → Development → Import plugin from manifest…\n'
        '     → $manifest\n'
        '  2. Run:  dart run tokenline sync\n'
        '  3. In Figma, open the Tokenline plugin. It syncs both ways.');
    return 0;
  }
}

/// Old name for [SetupCommand].
class InitCommand extends SetupCommand {
  @override
  String get name => 'init';

  @override
  bool get hidden => true;
}

String configTemplate({required String prefix, String? fileKey}) => '''
# tokenline — design tokens for Flutter, synced with Figma.
# Docs: https://github.com/alfatihtalab/tokenline
name: design-tokens
version: 0.1.0

tokens:
  dir: design_tokens
  primitives:            # raw values; * matches inside one folder
    - primitives/*.tokens.json
  modes:                 # one semantic file per theme, in order
    light: semantic/light.tokens.json
    dark: semantic/dark.tokens.json
  # components:
  #   - components/*.tokens.json

flutter:
  output_dir: lib/design_system/foundations/generated
  class_prefix: $prefix

figma:
  file_key: ${fileKey ?? 'PASTE_FILE_KEY'}   # only for CI pulls and icons; sync doesn't need it
  source: plugin         # plugin | variables-api (Enterprise) | sync-frame (legacy)
  name_case: kebab       # font/line-height/tight
  collections:
    primitives: Primitives
    semantic: Semantic
    # components: Component
  hide_primitives: true  # keep primitives out of pickers and the library
''';

const starterTokens = <String, Map<String, Object?>>{
  'primitives/colors.tokens.json': {
    'color': {
      r'$type': 'color',
      'neutral': {
        '0': {r'$value': '#FFFFFF'},
        '50': {r'$value': '#F7F7F8'},
        '100': {r'$value': '#EDEDF0'},
        '300': {r'$value': '#C5C6CC'},
        '500': {r'$value': '#80828C'},
        '700': {r'$value': '#4A4C55'},
        '900': {r'$value': '#1B1C21'},
      },
      'brand': {
        '50': {r'$value': '#E8F1FE'},
        '500': {r'$value': '#1B6FE8'},
        '700': {r'$value': '#1556B5'},
      },
      'red': {
        '500': {r'$value': '#D93636'},
      },
      'green': {
        '500': {r'$value': '#1F9D55'},
      },
    },
  },
  'primitives/spacing.tokens.json': {
    'space': {
      r'$type': 'dimension',
      '0': {r'$value': '0'},
      '4': {r'$value': '4'},
      '8': {r'$value': '8'},
      '12': {r'$value': '12'},
      '16': {r'$value': '16'},
      '24': {r'$value': '24'},
      '32': {r'$value': '32'},
    },
  },
  'primitives/radius.tokens.json': {
    'radius': {
      r'$type': 'dimension',
      'none': {r'$value': '0'},
      'sm': {r'$value': '4'},
      'md': {r'$value': '8'},
      'lg': {r'$value': '16'},
      'pill': {r'$value': '999'},
    },
  },
  'primitives/typography.tokens.json': {
    'font': {
      'family': {
        r'$type': 'fontFamily',
        'primary': {r'$value': 'Roboto'},
      },
      'weight': {
        r'$type': 'fontWeight',
        'regular': {r'$value': 400},
        'medium': {r'$value': 500},
        'bold': {r'$value': 700},
      },
      'size': {
        r'$type': 'dimension',
        'sm': {r'$value': '12'},
        'md': {r'$value': '14'},
        'lg': {r'$value': '16'},
        'xl': {r'$value': '20'},
        '2xl': {r'$value': '24'},
      },
      'lineHeight': {
        r'$type': 'number',
        'tight': {r'$value': 1.2},
        'normal': {r'$value': 1.5},
      },
    },
  },
  'primitives/motion.tokens.json': {
    'motion': {
      'duration': {
        r'$type': 'duration',
        'fast': {r'$value': '150ms'},
        'normal': {r'$value': '250ms'},
      },
      'easing': {
        r'$type': 'cubicBezier',
        'standard': {
          r'$value': [0.2, 0, 0, 1],
        },
      },
    },
  },
  'semantic/light.tokens.json': {
    'color': {
      r'$type': 'color',
      'background': {
        'base': {
          r'$value': '{color.neutral.50}',
          r'$description': 'App background.'
        },
      },
      'surface': {
        'default': {r'$value': '{color.neutral.0}'},
      },
      'text': {
        'primary': {r'$value': '{color.neutral.900}'},
        'secondary': {r'$value': '{color.neutral.700}'},
      },
      'border': {
        'subtle': {r'$value': '{color.neutral.100}'},
      },
      'action': {
        'primary': {r'$value': '{color.brand.500}'},
        'onPrimary': {r'$value': '{color.neutral.0}'},
      },
      'feedback': {
        'error': {r'$value': '{color.red.500}'},
        'success': {r'$value': '{color.green.500}'},
      },
    },
  },
  'semantic/dark.tokens.json': {
    'color': {
      r'$type': 'color',
      'background': {
        'base': {
          r'$value': '{color.neutral.900}',
          r'$description': 'App background.'
        },
      },
      'surface': {
        'default': {r'$value': '{color.neutral.700}'},
      },
      'text': {
        'primary': {r'$value': '{color.neutral.50}'},
        'secondary': {r'$value': '{color.neutral.300}'},
      },
      'border': {
        'subtle': {r'$value': '{color.neutral.700}'},
      },
      'action': {
        'primary': {r'$value': '{color.brand.50}'},
        'onPrimary': {r'$value': '{color.brand.700}'},
      },
      'feedback': {
        'error': {r'$value': '{color.red.500}'},
        'success': {r'$value': '{color.green.500}'},
      },
    },
  },
};
