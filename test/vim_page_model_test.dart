import 'package:flutter_test/flutter_test.dart';
import 'package:mdslens/services/vim_page_model.dart';

void main() {
  VimPageCell cell(String id, {int kind = 0}) => VimPageCell(
        id: id,
        label: id,
        kind: VimPageCellKind.values[kind],
      );

  test('page navigation keeps horizontal and vertical motions local', () {
    final stack = VimPageStack(
      root: VimPage(
        id: 'root',
        title: 'Application',
        rows: [
          [cell('open'), cell('save'), cell('settings', kind: 1)],
          [cell('plot-grid', kind: 1)],
        ],
      ),
    );

    expect(stack.move(VimPageMotion.first), isTrue);
    expect(stack.selectedId, 'open');
    expect(stack.move(VimPageMotion.right), isTrue);
    expect(stack.selectedId, 'save');
    expect(stack.move(VimPageMotion.down), isTrue);
    expect(stack.selectedId, 'plot-grid');
    // A boundary does not jump to another logical row or page.
    expect(stack.move(VimPageMotion.right), isFalse);
    expect(stack.selectedId, 'plot-grid');
    expect(stack.move(VimPageMotion.rowFirst), isFalse);
    expect(stack.selectedId, 'plot-grid');
  });

  test('gg, G, caret and dollar map to page and row edges', () {
    final stack = VimPageStack(
      root: VimPage(
        id: 'root',
        title: 'Application',
        rows: [
          [cell('a'), cell('b')],
          [cell('c'), cell('d'), cell('e')],
        ],
      ),
    );

    expect(stack.move(VimPageMotion.last), isTrue);
    expect(stack.selectedId, 'e');
    expect(stack.move(VimPageMotion.rowFirst), isTrue);
    expect(stack.selectedId, 'c');
    expect(stack.move(VimPageMotion.rowLast), isTrue);
    expect(stack.selectedId, 'e');
    expect(stack.move(VimPageMotion.first), isTrue);
    expect(stack.selectedId, 'a');
  });

  test('enter starts at first child and escape pops one page at a time', () {
    final stack = VimPageStack(
      root: VimPage(
        id: 'root',
        title: 'Application',
        rows: [
          [cell('settings', kind: 1)],
        ],
      ),
    );
    final settings = VimPage(
      id: 'settings',
      parentId: 'root',
      title: 'Settings',
      rows: [
        [cell('layout')],
        [cell('about')],
      ],
    );

    stack.setSelection('settings');
    expect(stack.push(settings), isTrue);
    expect(stack.selectedId, 'layout');
    expect(stack.pop(), isTrue);
    expect(stack.currentPage.id, 'root');
    expect(stack.selectedId, 'settings');
    expect(stack.pop(), isTrue);
    expect(stack.selectedId, isNull);
    expect(stack.pop(), isFalse);
  });

  test('disabled cells are skipped and preferred column is preserved', () {
    final stack = VimPageStack(
      root: VimPage(
        id: 'root',
        title: 'Application',
        rows: [
          [cell('a'), cell('b')],
          [
            cell('c'),
            VimPageCell(id: 'disabled', label: 'disabled', enabled: false)
          ],
          [cell('d'), cell('e')],
        ],
      ),
    );
    stack.move(VimPageMotion.first);
    stack.move(VimPageMotion.right);
    stack.move(VimPageMotion.down);
    expect(stack.selectedId, 'c');
    stack.move(VimPageMotion.down);
    expect(stack.selectedId, 'e');
  });
}
