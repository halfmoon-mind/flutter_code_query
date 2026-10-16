library my_lib;

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

part 'lib_part.dart';

class A {
  void _openDocs(BuildContext c) => c.go('/docs/intro');
}
