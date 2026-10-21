import 'dart:io';

import 'package:tokenline/src/cli.dart';

Future<void> main(List<String> args) async {
  exitCode = await runTokenline(args);
}
