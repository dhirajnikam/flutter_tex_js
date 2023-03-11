import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tex_js_platform_interface/flutter_tex_js_platform_interface.dart';

// Keep in sync with const of same name in text_style.dart
const double _kDefaultFontSize = 14;
// This is arbitrary
const Color _kDefaultTextColor = Colors.black;

TexRendererPlatform get _platform => TexRendererPlatform.instance;

class FlutterTexJs {
  /// Render the specified [text] to a PNG binary suitable for display with
  /// [Image.memory].
  ///
  /// [requestId] is an arbitrary ID that identifies this render
  /// request. Concurrent requests with the same ID will be coalesced: earlier
  /// requests will return with null, and only the last request will complete
  /// with data. You can also cancel a request with [cancel].
  ///
  /// [displayMode] is KaTeX's displayMode: math will be in display mode (\int,
  /// \sum, etc. will be large). This is appropriate for "block" display, as
  /// opposed to "inline" display. See also: https://katex.org/docs/options.html
  ///
  /// [color] is the color of the rendered text.
  ///
  /// [fontSize] is the size in pixels of the rendered text. You can use
  /// e.g. [TextStyle.fontSize] as-is.
  ///
  /// [maxWidth] is the width in pixels that the rendered image is allowed to
  /// take up. When [maxWidth] is [double.infinity] or [displayMode] is true,
  /// the width will be the natural width of the text. Only when [displayMode]
  /// is false and [maxWidth] is finite, this width determines where the text
  /// will wrap.
  static Future<Uint8List> render(
    String text, {
    required String requestId,
    required bool displayMode,
    required Color color,
    required double fontSize,
    required double maxWidth,
  }) async {
    assert(text.trim().isNotEmpty);
    final escapedText = _escapeForJavaScript(text);
    if (escapedText != text && !kReleaseMode) {
      debugPrint(
          'Escaped text to render; was: "$text"; escaped: "$escapedText"');
    }
    return await _platform.render(
      escapedText,
      requestId: requestId,
      displayMode: displayMode,
      color: _colorToCss(color),
      fontSize: fontSize,
      maxWidth: maxWidth,
    );
  }

  /// Cancel the in-flight [render] request identified by [requestId]. You might
  /// want to call this e.g. in StatefulWidget.dispose. It is safe to call this
  /// even if no such render request exists.
  static Future<void> cancel(String requestId) {
    return _platform.cancel(requestId);
  }
}

// Native layer will concatenate with apostrophes to form a JavaScript string
// literal; prepare here for that.
String _escapeForJavaScript(String string) => string
    .replaceAll(r'\', r'\\')
    .replaceAll('\n', r'\n')
    .replaceAll('\r', r'\r')
    .replaceAll("'", r"\'");

String _colorToCss(Color color) =>
    'rgba(${color.red},${color.green},${color.blue},${color.opacity})';

/// A set listing the supported TeX environments; see
/// https://katex.org/docs/support_table.html
const Set<String> flutterTexJsSupportedEnvironments = {
  'align',
  'align*',
  'aligned',
  'alignat',
  'alignat*',
  'alignedat',
  'array',
  'Bmatrix',
  'Bmatrix*',
  'bmatrix',
  'bmatrix*',
  'cases',
  'CD',
  'darray',
  'dcases',
  'drcases',
  'equation',
  'equation*',
  'gather',
  'gathered',
  'matrix',
  'matrix*',
  'pmatrix',
  'pmatrix*',
  'rcases',
  'smallmatrix',
  'split',
  'Vmatrix',
  'Vmatrix*',
  'vmatrix',
  'vmatrix*',
};

typedef ErrorWidgetBuilder = Widget Function(
    BuildContext context, Object error);

/// A rendered image of LaTeX markup. The image is rendered asynchronously by a
/// native web view.

class TexImage extends StatefulWidget {
  const TexImage(
    this.math, {
    this.displayMode = true,
    this.color,
    this.fontSize,
    this.placeholder,
    this.error,
    this.alignment = Alignment.center,
    this.keepAlive = true,
    Key? key,
  }) : super(key: key);

  /// LaTeX markup to render. See here for supported syntax:
  /// https://katex.org/docs/supported.html
  final String math;

  /// [displayMode] is KaTeX's displayMode: math will be in display mode (\int,
  /// \sum, etc. will be large). This is appropriate for "block" display, as
  /// opposed to "inline" display. See also: https://katex.org/docs/options.html
  final bool displayMode;

  /// [color] is the color of the rendered text.
  final Color? color;

  /// [fontSize] is the size in pixels of the rendered text. You can use
  /// e.g. [TextStyle.fontSize] as-is.
  final double? fontSize;

  /// A widget to display while rendering. By default it is simply [math] as
  /// text.
  final Widget? placeholder;

  /// A builder supplying a widget to display in case of error, for instance
  /// when [math] contains invalid or unsupported LaTeX syntax. By default it is
  /// [Icons.error] and the error message.
  final ErrorWidgetBuilder? error;

  /// Controls the alignment of the image within its bounding box; see
  /// [Image.alignment].
  final AlignmentGeometry alignment;

  /// Whether or not the rendered image should be retained even when e.g. the
  /// widget has been scrolled out of view in a [ListView].
  final bool keepAlive;

  @override
  State<TexImage> createState() => _TexImageState();
}

class _TexImageState extends State<TexImage>
    with AutomaticKeepAliveClientMixin<TexImage> {
  String get id =>
      widget.key?.hashCode.toString() ?? identityHashCode(this).toString();

  Future<Uint8List?>? _renderFuture;
  List? _renderArgs;

  @override
  void dispose() {
    FlutterTexJs.cancel(id);
    super.dispose();
  }

  // Memoize the Future object to prevent spurious re-renders, in particular
  // this loop:
  //
  // 1. Initial render
  // 2. Display of rendered image changes the layout, causing LayoutBuilder to
  //    run again, causing another render
  //
  // An optimization in Flutter 1.18 (not yet "stable" as of July 2020)
  // partially mitigates this, preventing an infinite loop but still
  // re-rendering unnecessarily once.
  //
  // See also:
  //
  //  * https://github.com/flutter/flutter/wiki/Changelog#v118x
  //  * https://github.com/amake/flutter_tex_js/pull/1
  Future<Uint8List?> _buildRenderFuture(
    String math, {
    required String requestId,
    required bool displayMode,
    required Color color,
    required double fontSize,
    required double maxWidth,
  }) {
    final args = [math, requestId, displayMode, color, fontSize, maxWidth];
    if (_renderFuture == null || !listEquals<dynamic>(args, _renderArgs)) {
      _renderFuture = FlutterTexJs.render(
        math,
        requestId: requestId,
        displayMode: displayMode,
        color: color,
        fontSize: fontSize,
        maxWidth: maxWidth,
      );
      _renderArgs = args;
    } else {
      debugPrint('Skipping unnecessary render of $requestId');
    }
    return _renderFuture!;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (widget.math.trim().isEmpty) {
      return Text(widget.math);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final textStyle = DefaultTextStyle.of(context).style;
        return FutureBuilder<Uint8List?>(
          future: _buildRenderFuture(
            widget.math,
            requestId: id,
            displayMode: widget.displayMode,
            color: widget.color ?? textStyle.color ?? _kDefaultTextColor,
            fontSize:
                widget.fontSize ?? textStyle.fontSize ?? _kDefaultFontSize,
            maxWidth: constraints.maxWidth,
          ),
          builder: (context, snapshot) {
            if (snapshot.hasData) {
              return Image.memory(
                snapshot.data!,
                alignment: widget.alignment,
                scale: MediaQuery.of(context).devicePixelRatio,
              );
            } else if (snapshot.hasError) {
              return _buildErrorWidget(snapshot.error!);
            } else {
              return widget.placeholder ?? Text(widget.math);
            }
          },
        );
      },
    );
  }

  Widget _buildErrorWidget(Object error) {
    if (error is PlatformException) {
      switch (error.code) {
        case 'UnsupportedOsVersion':
          return Text(widget.math);
        case 'JobCancelled':
          return const SizedBox.shrink();
      }
    }
    final errorBuilder = widget.error ?? defaultError;
    return errorBuilder(context, error);
  }

  Widget defaultError(BuildContext context, Object error) => Column(
        children: [
          const Icon(Icons.error),
          Text(error.toString()),
        ],
      );

  @override
  bool get wantKeepAlive => widget.keepAlive;
}

class AtomicKatex extends StatefulWidget {
  const AtomicKatex({
    Key? key,
    required this.laTeXCode,
    this.textStyle,
    this.delimiter = r'$',
    this.displayDelimiter = r'$$',
  }) : super(key: key);
  // a Text used for the rendered code as well as for the style
  final Text laTeXCode;

  final TextStyle? textStyle;

  // The delimiter to be used for inline LaTeX
  final String delimiter;

  // The delimiter to be used for Display (centered, "important") LaTeX
  final String displayDelimiter;

  @override
  State<AtomicKatex> createState() => _AtomicKatexState();
}

class _AtomicKatexState extends State<AtomicKatex> {
  @override
  @override
  Widget build(BuildContext context) {
    // Fetching the Widget's LaTeX code as well as it's [TextStyle]
    final String? laTeXCode = widget.laTeXCode.data;
    TextStyle? defaultTextStyle = widget.laTeXCode.style;

    // Building [RegExp] to find any Math part of the LaTeX code by looking for the specified delimiters
    final String delimiter = widget.delimiter.replaceAll(r'$', r'\$');
    final String displayDelimiter =
        widget.displayDelimiter.replaceAll(r'$', r'\$');

    final String rawRegExp =
        '(($delimiter)([^$delimiter]*[^\\\\\\$delimiter])($delimiter)|($displayDelimiter)([^$displayDelimiter]*[^\\\\\\$displayDelimiter])($displayDelimiter))';
    List<RegExpMatch> matches =
        RegExp(rawRegExp, dotAll: true).allMatches(laTeXCode!).toList();

    // If no single Math part found, returning the raw [Text] from widget.laTeXCode
    if (matches.isEmpty) return widget.laTeXCode;

    // Otherwise looping threw all matches and building a [RichText] from [TextSpan] and [WidgetSpan] widgets
    List<InlineSpan> textBlocks = [];
    int lastTextEnd = 0;

    for (var laTeXMatch in matches) {
      // If there is an offset between the lat match (beginning of the [String] in first case), first adding the found [Text]

      if (laTeXMatch.start > lastTextEnd) {
        textBlocks.add(
            TextSpan(text: laTeXCode.substring(lastTextEnd, laTeXMatch.start)));
      }
      // Adding the [CaTeX] widget to the children
      if (laTeXMatch.group(3) != null) {
        textBlocks.add(WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: TexImage(
              laTeXMatch.group(3)!.trim(),
              fontSize: 15,
              error: (context, error) {
                return Text("");
              },
            )));
      } else {
        textBlocks.addAll([
          const TextSpan(text: '\n'),
          WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: DefaultTextStyle.merge(
                child: Padding(
                  padding: const EdgeInsets.all(1.0),
                  child: TexImage(
                    laTeXMatch.group(6)!.trim(),
                    fontSize: 15,
                    error: (context, error) {
                      return Text("");
                    },
                  ),
                ),
              )),
          const TextSpan(text: '\n')
        ]);
      }
      lastTextEnd = laTeXMatch.end;
    }

    // If there is any text left after the end of the last match, adding it to children
    if (lastTextEnd < laTeXCode.length) {
      textBlocks.add(TextSpan(text: laTeXCode.substring(lastTextEnd)));
    }

    // Returning a RichText containing all the [TextSpan] and [WidgetSpan] created previously while
    // obeying the specified style in widget.laTeXCode
    return Text.rich(TextSpan(
        children: textBlocks,
        style: (defaultTextStyle == null)
            ? Theme.of(context).textTheme.bodyText1
            : defaultTextStyle));
  }
}
