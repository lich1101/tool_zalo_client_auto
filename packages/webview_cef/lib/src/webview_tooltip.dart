import 'dart:async';

import 'package:flutter/material.dart';

class WebviewTooltip {
  WebviewTooltip(BuildContext context) {
    _overlayState = Overlay.of(context);
    _box = context.findRenderObject() as RenderBox;
  }
  late OverlayState _overlayState;
  OverlayEntry? _overlayEntry;
  Timer? _timer;
  Offset cursorOffset = Offset.zero;
  late RenderBox _box;
  final TextStyle _textStyle =
      const TextStyle(color: Colors.black, fontSize: 14);

  // Remove the currently shown overlay, if any. Safe to call repeatedly: the
  // entry is nulled after removal so we never double-remove (which asserts).
  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  void _buildOverlayEntry(String text) {
    //往Overlay中插入插入OverlayEntry
    _timer = Timer(const Duration(milliseconds: 500), () {
      // Defensive: never leave a previous overlay in the tree when inserting a
      // new one — that is what made tooltips stack on top of each other.
      _removeOverlay();
      _overlayEntry = OverlayEntry(builder: (context) {
        double height = _box.size.height;
        double width = _box.size.width;
        TextPainter textPainter = TextPainter(
          locale: Localizations.localeOf(context),
          textDirection: TextDirection.ltr,
          text: TextSpan(text: text, style: _textStyle),
          maxLines: 5,
          ellipsis: '...',
        )..layout(maxWidth: width - 16);
        if (cursorOffset.dy + textPainter.height + 25 > height) {
          cursorOffset =
              Offset(cursorOffset.dx, height - textPainter.height - 10);
          if (cursorOffset.dy < 0) {
            cursorOffset = Offset(cursorOffset.dx, 0);
          }
        } else {
          cursorOffset = Offset(cursorOffset.dx, cursorOffset.dy + 15);
        }

        if (cursorOffset.dx + textPainter.width + 40 > width) {
          cursorOffset =
              Offset(width - textPainter.width - 25, cursorOffset.dy);
          if (cursorOffset.dx < 0) {
            cursorOffset = Offset(0, cursorOffset.dy);
          }
        } else {
          cursorOffset = Offset(cursorOffset.dx + 15, cursorOffset.dy);
        }
        return Positioned(
          top: cursorOffset.dy,
          left: cursorOffset.dx,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: textPainter.width + 16,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: const BorderRadius.all(Radius.circular(4)),
                boxShadow: [
                  BoxShadow(
                      blurRadius: 2, color: Colors.black.withValues(alpha: .2))
                ],
              ),
              child: RichText(
                text: TextSpan(text: text, style: _textStyle),
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        );
      });
      _overlayState.insert(_overlayEntry!);
    });
  }

  void showToolTip(String text) {
    // Any new tooltip event supersedes the previous one. Cancel a pending
    // show-timer and remove an already-shown overlay BEFORE doing anything
    // else, so at most one tooltip is ever in the tree (no stacking).
    _timer?.cancel();
    _removeOverlay();

    if (text.isEmpty) {
      return;
    }

    _buildOverlayEntry(text);
  }
}
