import 'dart:convert';
import 'dart:io';

import 'package:flutter_code_query/flutter_code_query.dart';

const _usage = '''
Usage: flutter_code_query <command> [--root=<project>]

Commands:
  check          Repo-wide navigation findings, warnings first.
  query <route>  Incoming navigation candidates for one route.
  routes         Registered GoRoute paths.

Parses <project>/lib (default: the current directory) without resolving
types; output is JSON on stdout.''';

void main(List<String> args) {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln(_usage);
    return;
  }
  final options = args.where((a) => a.startsWith('-')).toList();
  final positional = args.where((a) => !a.startsWith('-')).toList();
  final command = positional.firstOrNull;
  final valid = options.every((o) => o.startsWith('--root=')) &&
      options.length <= 1 &&
      switch (command) {
        'check' || 'routes' => positional.length == 1,
        'query' => positional.length == 2,
        _ => false,
      };
  if (!valid) {
    stderr.writeln(_usage);
    exitCode = 2;
    return;
  }
  final root = options.firstOrNull?.substring('--root='.length) ?? '.';
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
