import 'dart:async';

import 'package:flutter/material.dart' as m;

import 'live_translation_service.dart';

/// Drop-in replacement for Flutter's Text widget.
///
/// It keeps the Flutter Text API, uses curated translations synchronously where
/// available, and translates uncatalogued UI copy in the background. Existing
/// layouts therefore keep their styles and dimensions while language changes
/// update live.
class Text extends m.StatelessWidget {
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
    this.textScaler,
    this.textScaleFactor,
    this.maxLines,
    this.semanticsLabel,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  }) : textSpan = null;

  const Text.rich(
    m.InlineSpan text, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.textScaleFactor,
    this.maxLines,
    this.semanticsLabel,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  })  : data = null,
        textSpan = text;

  final String? data;
  final m.InlineSpan? textSpan;
  final m.TextStyle? style;
  final m.StrutStyle? strutStyle;
  final m.TextAlign? textAlign;
  final m.TextDirection? textDirection;
  final m.Locale? locale;
  final bool? softWrap;
  final m.TextOverflow? overflow;
  final m.TextScaler? textScaler;
  @Deprecated('Use textScaler instead.')
  final double? textScaleFactor;
  final int? maxLines;
  final String? semanticsLabel;
  final m.TextWidthBasis? textWidthBasis;
  final m.TextHeightBehavior? textHeightBehavior;
  final m.Color? selectionColor;

  m.TextScaler? get _effectiveScaler =>
      textScaler ??
      (textScaleFactor == null
          ? null
          : m.TextScaler.linear(textScaleFactor!));

  @override
  m.Widget build(m.BuildContext context) {
    if (textSpan != null) {
      // Preserve rich styling and recognizers; simple Text widgets get full
      // live translation. Rich spans remain safe if they contain widgets.
      return m.Text.rich(
        textSpan!,
        style: style,
        strutStyle: strutStyle,
        textAlign: textAlign,
        textDirection: textDirection,
        locale: locale,
        softWrap: softWrap,
        overflow: overflow,
        textScaler: _effectiveScaler,
        maxLines: maxLines,
        semanticsLabel: semanticsLabel,
        textWidthBasis: textWidthBasis,
        textHeightBehavior: textHeightBehavior,
        selectionColor: selectionColor,
      );
    }

    return _LiveTranslationText(
      data: data ?? '',
      style: style,
      strutStyle: strutStyle,
      textAlign: textAlign,
      textDirection: textDirection,
      locale: locale,
      softWrap: softWrap,
      overflow: overflow,
      textScaler: _effectiveScaler,
      maxLines: maxLines,
      semanticsLabel: semanticsLabel,
      textWidthBasis: textWidthBasis,
      textHeightBehavior: textHeightBehavior,
      selectionColor: selectionColor,
    );
  }
}

class _LiveTranslationText extends m.StatefulWidget {
  const _LiveTranslationText({
    required this.data,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  });

  final String data;
  final m.TextStyle? style;
  final m.StrutStyle? strutStyle;
  final m.TextAlign? textAlign;
  final m.TextDirection? textDirection;
  final m.Locale? locale;
  final bool? softWrap;
  final m.TextOverflow? overflow;
  final m.TextScaler? textScaler;
  final int? maxLines;
  final String? semanticsLabel;
  final m.TextWidthBasis? textWidthBasis;
  final m.TextHeightBehavior? textHeightBehavior;
  final m.Color? selectionColor;

  @override
  m.State<_LiveTranslationText> createState() => _LiveTranslationTextState();
}

class _LiveTranslationTextState extends m.State<_LiveTranslationText> {
  String _displayText = '';
  String? _lastInput;
  String? _lastLanguage;
  int _requestGeneration = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _refreshTranslation();
  }

  @override
  void didUpdateWidget(covariant _LiveTranslationText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data ||
        oldWidget.locale != widget.locale) {
      _refreshTranslation();
    }
  }

  void _refreshTranslation() {
    final languageCode =
        widget.locale?.languageCode ?? m.Localizations.localeOf(context).languageCode;
    if (_lastInput == widget.data && _lastLanguage == languageCode) return;

    _lastInput = widget.data;
    _lastLanguage = languageCode;
    final generation = ++_requestGeneration;
    final local = LiveTranslationService.bundledTranslation(
      widget.data,
      languageCode,
    );
    _displayText = local ?? widget.data;

    if (languageCode == 'en' ||
        local != null ||
        !LiveTranslationService.shouldTranslate(widget.data, languageCode)) {
      return;
    }

    unawaited(_loadRemoteTranslation(
      widget.data,
      languageCode,
      generation,
    ));
  }

  Future<void> _loadRemoteTranslation(
    String source,
    String languageCode,
    int generation,
  ) async {
    final result = await LiveTranslationService.translate(source, languageCode);
    if (!mounted || generation != _requestGeneration || result == source) return;
    setState(() => _displayText = result);
  }

  @override
  m.Widget build(m.BuildContext context) => m.Text(
        _displayText.isEmpty ? widget.data : _displayText,
        style: widget.style,
        strutStyle: widget.strutStyle,
        textAlign: widget.textAlign,
        textDirection: widget.textDirection,
        locale: widget.locale,
        softWrap: widget.softWrap,
        overflow: widget.overflow,
        textScaler: widget.textScaler,
        maxLines: widget.maxLines,
        semanticsLabel: widget.semanticsLabel,
        textWidthBasis: widget.textWidthBasis,
        textHeightBehavior: widget.textHeightBehavior,
        selectionColor: widget.selectionColor,
      );
}
