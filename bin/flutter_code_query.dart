import 'dart:convert';
import 'dart:io';

import 'package:flutter_code_query/flutter_code_query.dart';

const _usage = '''
Usage: flutter_code_query <command> [--root=<project>]

Commands:
  check          Repo-wide navigation findings.
  query <route>  Incoming navigation candidates for one route.
  routes         Registered GoRoute paths.

Parses lib/ without resolving types; output is JSON on stdout.''';

void main(List<String> args) {
  final root = args
          .where((a) => a.startsWith('--root='))
          .map((a) => a.substring('--root='.length))
          .firstOrNull ??
      '.';
  final positional = args.where((a) => !a.startsWith('--')).toList();
  final command = positional.firstOrNull;
  if (args.contains('--help') ||
      command == null ||
      (command == 'query') != (positional.length == 2) ||
      positional.length > 2 ||
      !const {'check', 'query', 'routes'}.contains(command)) {
    stderr.writeln(_usage);
    exitCode = 2;
    return;
  }
  if (!Directory('$root/lib').existsSync()) {
    stderr.writeln('No lib/ directory under $root');
    exitCode = 2;
    return;
  }
  final index = CodeIndex.build(root);
  final result = switch (command) {
    'check' => check(index),
    'query' => query(index, positional[1]),
    _ => routeList(index),
  };
  stdout.writeln(const JsonEncoder.withIndent(' ').convert(result));
}
