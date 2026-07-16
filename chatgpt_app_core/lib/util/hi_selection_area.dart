import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

class HiSelectionArea {
  ///为包裹的Text提供文本选择的能力
  static Widget wrap(Text child, {bool selectAll = true, bool copy = true}) {
    //获取选择的文本
    var selectedText = '';
    return SelectionArea(
      child: child,
      onSelectionChanged: (SelectedContent? selectContent) =>
          selectedText = selectContent?.plainText ?? "",
      contextMenuBuilder: (
        BuildContext context,
        SelectableRegionState selectableRegionState,
      ) {
        bool selectAllEnable = false;
        //若还有可选的内则展示全选菜单
        if (selectedText.length < (child.data?.length ?? 0)) {
          selectAllEnable = true;
        }
        final buttonItems = selectableRegionState.contextMenuButtonItems
            .where((item) => switch (item.type) {
                  ContextMenuButtonType.selectAll =>
                    selectAll && selectAllEnable,
                  ContextMenuButtonType.copy => copy,
                  _ => false,
                })
            .toList();
        return AdaptiveTextSelectionToolbar.buttonItems(
            buttonItems: buttonItems,
            anchors: selectableRegionState.contextMenuAnchors);
      },
    );
  }
}
