import 'package:flutter/material.dart';

Widget separatedDropdownItem(
  BuildContext context, {
  Key? key,
  required Widget child,
  required bool isLast,
}) {
  return Container(
    key: key,
    width: double.infinity,
    alignment: Alignment.centerLeft,
    padding: const EdgeInsets.symmetric(horizontal: 8),
    decoration: isLast
        ? null
        : BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).dividerColor.withValues(alpha: 0.55),
              ),
            ),
          ),
    child: child,
  );
}

List<PopupMenuEntry<T>> separatedPopupMenuItems<T>(
  List<PopupMenuItem<T>> items,
) {
  return [
    for (var index = 0; index < items.length; index++) ...[
      if (index > 0) const PopupMenuDivider(height: 1),
      items[index],
    ],
  ];
}
