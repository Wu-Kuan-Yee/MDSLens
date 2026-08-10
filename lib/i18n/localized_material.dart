// ignore_for_file: deprecated_member_use

import 'package:flutter/material.dart' as material;

import 'language_scope.dart';

export 'package:flutter/material.dart' hide Text, Tooltip, SelectableText;
export 'language_scope.dart' show TranslatedBuildContext;

/// Drop-in localized counterpart of Flutter's [material.Text].
///
/// Keeping the familiar constructor means ordinary control labels cannot
/// accidentally bypass the runtime language catalog. The English source text
/// is also the stable message key, similar to gettext, so adding a language is
/// only a data-file operation and does not regenerate Dart source.
class Text extends material.StatelessWidget {
  const Text(
    String this.data, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    @Deprecated('Use textScaler instead.') this.textScaleFactor,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.semanticsIdentifier,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  }) : textSpan = null;

  const Text.rich(
    material.InlineSpan this.textSpan, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    @Deprecated('Use textScaler instead.') this.textScaleFactor,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.semanticsIdentifier,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  }) : data = null;

  final String? data;
  final material.InlineSpan? textSpan;
  final material.TextStyle? style;
  final material.StrutStyle? strutStyle;
  final material.TextAlign? textAlign;
  final material.TextDirection? textDirection;
  final material.Locale? locale;
  final bool? softWrap;
  final material.TextOverflow? overflow;
  final double? textScaleFactor;
  final material.TextScaler? textScaler;
  final int? maxLines;
  final String? semanticsLabel;
  final String? semanticsIdentifier;
  final material.TextWidthBasis? textWidthBasis;
  final material.TextHeightBehavior? textHeightBehavior;
  final material.Color? selectionColor;

  @override
  material.Widget build(material.BuildContext context) {
    final localizedSemantics =
        semanticsLabel == null ? null : context.tr(semanticsLabel!);
    if (data != null) {
      return material.Text(
        context.tr(data!),
        style: style,
        strutStyle: strutStyle,
        textAlign: textAlign,
        textDirection: textDirection,
        locale: locale,
        softWrap: softWrap,
        overflow: overflow,
        textScaleFactor: textScaleFactor,
        textScaler: textScaler,
        maxLines: maxLines,
        semanticsLabel: localizedSemantics,
        semanticsIdentifier: semanticsIdentifier,
        textWidthBasis: textWidthBasis,
        textHeightBehavior: textHeightBehavior,
        selectionColor: selectionColor,
      );
    }
    return material.Text.rich(
      _localizedSpan(context, textSpan!),
      style: style,
      strutStyle: strutStyle,
      textAlign: textAlign,
      textDirection: textDirection,
      locale: locale,
      softWrap: softWrap,
      overflow: overflow,
      textScaleFactor: textScaleFactor,
      textScaler: textScaler,
      maxLines: maxLines,
      semanticsLabel: localizedSemantics,
      semanticsIdentifier: semanticsIdentifier,
      textWidthBasis: textWidthBasis,
      textHeightBehavior: textHeightBehavior,
      selectionColor: selectionColor,
    );
  }
}

/// Selectable counterpart of [Text] that uses the same source-keyed catalog.
///
/// `SelectableText` is not covered by Flutter's ordinary `Text` widget, so a
/// direct use would otherwise be the one easy way for a visible string to
/// bypass the active language.  Keep this API close to Flutter's widget and
/// translate both the plain and rich forms at build time, just like [Text].
class SelectableText extends material.StatelessWidget {
  const SelectableText(
    String this.data, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    @Deprecated('Use textScaler instead.') this.textScaleFactor,
    this.textScaler,
    this.maxLines,
    this.selectionColor,
    this.semanticsLabel,
    this.textHeightBehavior,
    this.textWidthBasis,
  }) : textSpan = null;

  const SelectableText.rich(
    material.TextSpan this.textSpan, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    @Deprecated('Use textScaler instead.') this.textScaleFactor,
    this.textScaler,
    this.maxLines,
    this.selectionColor,
    this.semanticsLabel,
    this.textHeightBehavior,
    this.textWidthBasis,
  }) : data = null;

  final String? data;
  final material.TextSpan? textSpan;
  final material.TextStyle? style;
  final material.StrutStyle? strutStyle;
  final material.TextAlign? textAlign;
  final material.TextDirection? textDirection;
  final double? textScaleFactor;
  final material.TextScaler? textScaler;
  final int? maxLines;
  final material.Color? selectionColor;
  final String? semanticsLabel;
  final material.TextHeightBehavior? textHeightBehavior;
  final material.TextWidthBasis? textWidthBasis;

  @override
  material.Widget build(material.BuildContext context) {
    final localizedSemantics =
        semanticsLabel == null ? null : context.tr(semanticsLabel!);
    if (data != null) {
      return material.SelectableText(
        context.tr(data!),
        key: key,
        style: style,
        strutStyle: strutStyle,
        textAlign: textAlign,
        textDirection: textDirection,
        textScaleFactor: textScaleFactor,
        textScaler: textScaler,
        maxLines: maxLines,
        selectionColor: selectionColor,
        semanticsLabel: localizedSemantics,
        textHeightBehavior: textHeightBehavior,
        textWidthBasis: textWidthBasis,
      );
    }
    return material.SelectableText.rich(
      _localizedTextSpan(context, textSpan!),
      key: key,
      style: style,
      strutStyle: strutStyle,
      textAlign: textAlign,
      textDirection: textDirection,
      textScaleFactor: textScaleFactor,
      textScaler: textScaler,
      maxLines: maxLines,
      selectionColor: selectionColor,
      semanticsLabel: localizedSemantics,
      textHeightBehavior: textHeightBehavior,
      textWidthBasis: textWidthBasis,
    );
  }
}

class Tooltip extends material.StatelessWidget {
  const Tooltip({
    super.key,
    this.message,
    this.richMessage,
    this.height,
    this.constraints,
    this.padding,
    this.margin,
    this.verticalOffset,
    this.preferBelow,
    this.excludeFromSemantics,
    this.decoration,
    this.textStyle,
    this.textAlign,
    this.waitDuration,
    this.showDuration,
    this.exitDuration,
    this.enableTapToDismiss = true,
    this.triggerMode,
    this.enableFeedback,
    this.onTriggered,
    this.mouseCursor,
    this.ignorePointer,
    this.positionDelegate,
    this.child,
  }) : assert((message == null) != (richMessage == null));

  final String? message;
  final material.InlineSpan? richMessage;
  final double? height;
  final material.BoxConstraints? constraints;
  final material.EdgeInsetsGeometry? padding;
  final material.EdgeInsetsGeometry? margin;
  final double? verticalOffset;
  final bool? preferBelow;
  final bool? excludeFromSemantics;
  final material.Decoration? decoration;
  final material.TextStyle? textStyle;
  final material.TextAlign? textAlign;
  final Duration? waitDuration;
  final Duration? showDuration;
  final Duration? exitDuration;
  final bool enableTapToDismiss;
  final material.TooltipTriggerMode? triggerMode;
  final bool? enableFeedback;
  final material.TooltipTriggeredCallback? onTriggered;
  final material.MouseCursor? mouseCursor;
  final bool? ignorePointer;
  final material.TooltipPositionDelegate? positionDelegate;
  final material.Widget? child;

  @override
  material.Widget build(material.BuildContext context) => material.Tooltip(
        message: message == null ? null : context.tr(message!),
        richMessage:
            richMessage == null ? null : _localizedSpan(context, richMessage!),
        height: height,
        constraints: constraints,
        padding: padding,
        margin: margin,
        verticalOffset: verticalOffset,
        preferBelow: preferBelow,
        excludeFromSemantics: excludeFromSemantics,
        decoration: decoration,
        textStyle: textStyle,
        textAlign: textAlign,
        waitDuration: waitDuration,
        showDuration: showDuration,
        exitDuration: exitDuration,
        enableTapToDismiss: enableTapToDismiss,
        triggerMode: triggerMode,
        enableFeedback: enableFeedback,
        onTriggered: onTriggered,
        mouseCursor: mouseCursor,
        ignorePointer: ignorePointer,
        positionDelegate: positionDelegate,
        child: child,
      );
}

material.InlineSpan _localizedSpan(
  material.BuildContext context,
  material.InlineSpan span,
) {
  if (span is! material.TextSpan) return span;
  return material.TextSpan(
    text: span.text == null ? null : context.tr(span.text!),
    children: span.children
        ?.map((child) => _localizedSpan(context, child))
        .toList(growable: false),
    style: span.style,
    recognizer: span.recognizer,
    mouseCursor: span.mouseCursor,
    onEnter: span.onEnter,
    onExit: span.onExit,
    semanticsLabel:
        span.semanticsLabel == null ? null : context.tr(span.semanticsLabel!),
    semanticsIdentifier: span.semanticsIdentifier,
    locale: span.locale,
    spellOut: span.spellOut,
  );
}

material.TextSpan _localizedTextSpan(
  material.BuildContext context,
  material.TextSpan span,
) {
  return _localizedSpan(context, span) as material.TextSpan;
}
