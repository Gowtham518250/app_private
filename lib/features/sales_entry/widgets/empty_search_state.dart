import 'package:flutter/material.dart' hide Text;
import 'package:retail_mind/live_localized_text.dart';

class EmptySearchState extends StatelessWidget {
  const EmptySearchState({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text('No Results Found'),
    );
  }
}