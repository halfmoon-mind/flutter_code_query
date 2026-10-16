part of my_lib;

class B extends StatelessWidget {
  const B({super.key});

  @override
  Widget build(BuildContext context) =>
      GestureDetector(onTap: () => A()._openDocs(context));
}
