import 'package:flutter/material.dart';

import 'update_service.dart';

/// Manual "Check for updates" control.
///
/// Deliberately manual for now: an auto-check on launch is a fine addition, but
/// it must never block startup in a vineyard with poor signal. Prove the loop
/// works by hand first.
class UpdateButton extends StatefulWidget {
  const UpdateButton({super.key, this.service});

  final UpdateService? service;

  @override
  State<UpdateButton> createState() => _UpdateButtonState();
}

enum _Stage { idle, checking, downloading, installing }

class _UpdateButtonState extends State<UpdateButton> {
  late final UpdateService _service = widget.service ?? UpdateService();

  _Stage _stage = _Stage.idle;
  String? _message;
  double? _progress;

  bool get _busy => _stage != _Stage.idle;

  Future<void> _run() async {
    setState(() {
      _stage = _Stage.checking;
      _message = null;
      _progress = null;
    });

    final result = await _service.check();
    if (!mounted) return;

    switch (result) {
      case UpToDate(:final current):
        setState(() {
          _stage = _Stage.idle;
          _message = 'Up to date (v$current).';
        });

      case UpdateCheckFailed(:final message):
        setState(() {
          _stage = _Stage.idle;
          _message = message;
        });

      case UpdateAvailable(:final current, :final info):
        setState(() {
          _stage = _Stage.downloading;
          _message = 'Downloading v${info.version} (from v$current)...';
        });

        try {
          final apk = await _service.download(
            info,
            onProgress: (p) {
              if (mounted) setState(() => _progress = p);
            },
          );
          if (!mounted) return;

          setState(() {
            _stage = _Stage.installing;
            _progress = null;
            _message = 'Opening installer...';
          });

          final error = await _service.install(apk);
          if (!mounted) return;

          setState(() {
            _stage = _Stage.idle;
            _message = error ?? 'Installer opened. Follow the prompts.';
          });
        } catch (e) {
          if (!mounted) return;
          setState(() {
            _stage = _Stage.idle;
            _progress = null;
            _message = 'Download failed: $e';
          });
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FilledButton.tonalIcon(
          // Large hit target: this gets used outdoors, possibly with gloves.
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 18),
          ),
          onPressed: _busy ? null : _run,
          icon: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.system_update),
          label: Text(switch (_stage) {
            _Stage.idle => 'Check for updates',
            _Stage.checking => 'Checking...',
            _Stage.downloading => 'Downloading...',
            _Stage.installing => 'Installing...',
          }),
        ),
        if (_progress != null) ...[
          const SizedBox(height: 12),
          SizedBox(
            width: 240,
            child: LinearProgressIndicator(value: _progress),
          ),
          const SizedBox(height: 4),
          Text(
            '${(_progress! * 100).toStringAsFixed(0)}%',
            style: theme.textTheme.bodySmall,
          ),
        ],
        if (_message != null) ...[
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Text(
              _message!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
