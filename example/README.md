# Example

In a Flutter app:

```bash
dart pub add --dev tokenline
dart run tokenline init --prefix App --file-key <figma file key>
dart run tokenline plugin     # install the Figma plugin
dart run tokenline push       # create the variables in Figma
# designers edit, Lint, publish, Export
dart run tokenline pull       # token files + Dart, ready to review
```

Then use the generated classes:

```dart
import 'package:my_app/design_system/foundations/generated/app_colors.g.dart';
import 'package:my_app/design_system/foundations/generated/app_spacing.g.dart';

final padding = EdgeInsets.all(AppSpacing.space16);
final ink = AppColorsLight.textPrimary;
```
