import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:url_launcher/url_launcher.dart';

import 'home_page.dart';

final _androidTunnelController = AndroidTunnelController();

class AndroidTunnelController extends ChangeNotifier {
  FFI? _ffi;
  bool running = false;
  String peerId = '';
  String remoteHost = '';
  int remotePort = 0;
  int localPort = 0;
  bool? secure;
  bool? direct;
  bool? mux;
  String streamType = '';
  String peerVersion = '';

  String get localUrl => localPort > 0 ? 'http://127.0.0.1:$localPort' : '';

  String get connectionLabel =>
      mux == null ? 'Waiting for traffic' : 'Connected';

  String get encryptionLabel {
    if (mux == null) return 'Pending';
    if (secure != true) return 'Insecure';
    return mux == true ? 'E2EE' : 'Legacy / raw';
  }

  String get tunnelModeLabel =>
      mux == null ? 'Pending' : (mux == true ? 'MUX' : 'Legacy');

  String get transportLabel {
    if (direct == null) return 'Pending';
    final path = direct == true ? 'Direct' : 'Relay';
    return streamType.isEmpty ? path : '$path ($streamType)';
  }

  bool get hasSecurityWarning =>
      mux == false || (mux != null && secure != true);

  String get securityWarning {
    if (secure != true && mux != null) {
      return 'The RustDesk session is not end-to-end encrypted.';
    }
    if (mux == false) {
      return 'Legacy forwarding is active. TCP payload leaves the RustDesk '
          'encrypted session after login.';
    }
    return '';
  }

  void _syncStatus() {
    final model = _ffi?.ffiModel;
    if (model == null) return;
    secure = model.secure;
    direct = model.direct;
    mux = model.portForwardMux;
    streamType = model.cachedPeerData.streamType;
    peerVersion = model.portForwardPeerVersion;
    notifyListeners();
  }

  void _resetStatus() {
    secure = null;
    direct = null;
    mux = null;
    streamType = '';
    peerVersion = '';
  }

  Future<void> start({
    required String peerId,
    required String password,
    required int localPort,
    required String remoteHost,
    required int remotePort,
  }) async {
    if (running) {
      await stop();
    }

    final ffi = FFI(null, forceUniqueSession: true);
    _ffi = ffi;
    _resetStatus();
    ffi.ffiModel.addListener(_syncStatus);
    this.peerId = peerId;
    this.remoteHost = remoteHost;
    this.remotePort = remotePort;
    this.localPort = localPort;

    try {
      ffi.start(
        peerId,
        isPortForward: true,
        password: password,
      );

      // Keep the same persisted port-forward configuration used by RustDesk's
      // desktop tunnel page. Only replace an existing mapping when this local
      // port points at a different remote endpoint; preserve all other saved
      // mappings for the peer.
      try {
        final peer = bind.mainGetPeerSync(id: peerId);
        final config = jsonDecode(peer) as Map<String, dynamic>;
        final existing =
            (config['port_forwards'] as List<dynamic>? ?? const <dynamic>[]);
        for (final item in existing) {
          if (item is List &&
              item.length >= 3 &&
              item[0] == localPort &&
              (item[1] != remoteHost || item[2] != remotePort)) {
            await bind.sessionRemovePortForward(
              sessionId: ffi.sessionId,
              localPort: localPort,
            );
            break;
          }
        }
      } catch (e) {
        debugPrint('Failed to inspect saved tunnel mappings: $e');
      }

      await bind.sessionAddPortForward(
        sessionId: ffi.sessionId,
        localPort: localPort,
        remoteHost: remoteHost,
        remotePort: remotePort,
      );

      final ok = await ffi.invokeMethod(
        'start_tunnel_service',
        {
          'description':
              '127.0.0.1:$localPort -> $remoteHost:$remotePort via $peerId',
        },
      );
      if (!ok) {
        throw StateError('Unable to start Android tunnel service');
      }
      running = true;
      notifyListeners();
    } catch (_) {
      await _closeSession();
      rethrow;
    }
  }

  Future<void> stop() async {
    if (_ffi != null && localPort > 0) {
      try {
        await bind.sessionRemovePortForward(
          sessionId: _ffi!.sessionId,
          localPort: localPort,
        );
      } catch (e) {
        debugPrint('Failed to remove tunnel mapping: $e');
      }
    }
    await _closeSession();
    running = false;
    peerId = '';
    remoteHost = '';
    remotePort = 0;
    localPort = 0;
    _resetStatus();
    notifyListeners();
  }

  Future<void> _closeSession() async {
    final ffi = _ffi;
    _ffi = null;
    if (ffi != null) {
      ffi.ffiModel.removeListener(_syncStatus);
      try {
        await ffi.close();
      } catch (e) {
        debugPrint('Failed to close tunnel session: $e');
      }
      try {
        await ffi.invokeMethod('stop_tunnel_service');
      } catch (e) {
        debugPrint('Failed to stop tunnel service: $e');
      }
    }
  }
}

class TunnelPage extends StatefulWidget implements PageShape {
  const TunnelPage({super.key});

  @override
  final icon = const Icon(Icons.swap_horiz);

  @override
  final title = translate('Tunnel');

  @override
  final List<Widget> appBarActions = const [];

  @override
  State<TunnelPage> createState() => _TunnelPageState();
}

class _TunnelPageState extends State<TunnelPage> {
  final _peerId = TextEditingController();
  final _password = TextEditingController();
  final _localPort = TextEditingController(text: '18080');
  final _remoteHost = TextEditingController(text: '192.168.1.1');
  final _remotePort = TextEditingController(text: '80');

  bool _working = false;
  bool _obscurePassword = true;
  bool _loadingSavedPeer = false;

  bool get _running => _androidTunnelController.running;

  @override
  void initState() {
    super.initState();
    if (_running) {
      _peerId.text = _androidTunnelController.peerId;
      _localPort.text = _androidTunnelController.localPort.toString();
      _remoteHost.text = _androidTunnelController.remoteHost;
      _remotePort.text = _androidTunnelController.remotePort.toString();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadLastSavedPeer();
      });
    }
    _androidTunnelController.addListener(_onTunnelStatusChanged);
  }

  Future<void> _loadLastSavedPeer() async {
    if (_loadingSavedPeer || _running) return;
    _loadingSavedPeer = true;
    try {
      final id = (await bind.mainGetLastRemoteId()).trim();
      if (id.isEmpty || !mounted) return;
      _peerId.text = id;
      _loadSavedTunnelForPeer(id);
    } catch (e) {
      debugPrint('Failed to load last saved peer for tunnel: $e');
    } finally {
      _loadingSavedPeer = false;
    }
  }

  void _loadSavedTunnelForPeer(String peerId) {
    try {
      final peer = bind.mainGetPeerSync(id: peerId);
      final config = jsonDecode(peer) as Map<String, dynamic>;
      final existing =
          (config['port_forwards'] as List<dynamic>? ?? const <dynamic>[]);
      if (existing.isEmpty) return;

      final item = existing.first;
      if (item is List && item.length >= 3) {
        final localPort = item[0];
        final remoteHost = item[1];
        final remotePort = item[2];
        if (localPort is int) {
          _localPort.text = localPort.toString();
        }
        if (remoteHost is String && remoteHost.isNotEmpty) {
          _remoteHost.text = remoteHost;
        }
        if (remotePort is int) {
          _remotePort.text = remotePort.toString();
        }
      }
    } catch (e) {
      debugPrint('Failed to load saved tunnel mapping for $peerId: $e');
    }
  }

  void _onTunnelStatusChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _androidTunnelController.removeListener(_onTunnelStatusChanged);
    _peerId.dispose();
    _password.dispose();
    _localPort.dispose();
    _remoteHost.dispose();
    _remotePort.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final disabled = _working || _running;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'RustDesk TCP Tunnel',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(
          'Expose one remote LAN TCP service on this phone as 127.0.0.1. '
          'The last RustDesk ID, remembered password, and saved tunnel mapping '
          'are reused automatically. No VPNService or root is used.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 24),
        _field(
          controller: _peerId,
          label: 'RustDesk ID',
          hint: '123456789',
          enabled: !disabled,
          keyboardType: TextInputType.number,
          onSubmitted: (value) => _loadSavedTunnelForPeer(value.trim()),
        ),
        _field(
          controller: _password,
          label: 'Password',
          hint: 'RustDesk peer password',
          enabled: !disabled,
          obscureText: _obscurePassword,
          suffixIcon: IconButton(
            onPressed: disabled
                ? null
                : () => setState(() => _obscurePassword = !_obscurePassword),
            icon: Icon(
              _obscurePassword ? Icons.visibility : Icons.visibility_off,
            ),
          ),
          helperText: 'Leave blank to use the password already saved for this ID',
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _field(
                controller: _localPort,
                label: 'Local Port',
                hint: '18080',
                enabled: !disabled,
                keyboardType: TextInputType.number,
                numbersOnly: true,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _field(
                controller: _remotePort,
                label: 'Remote Port',
                hint: '80',
                enabled: !disabled,
                keyboardType: TextInputType.number,
                numbersOnly: true,
              ),
            ),
          ],
        ),
        _field(
          controller: _remoteHost,
          label: 'Remote Host',
          hint: '192.168.1.100',
          enabled: !disabled,
        ),
        const SizedBox(height: 8),
        if (_running)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.check_circle, color: Colors.green),
                      const SizedBox(width: 8),
                      Text(
                        'Listening',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SelectableText(_androidTunnelController.localUrl),
                  const SizedBox(height: 4),
                  Text(
                    '${_androidTunnelController.remoteHost}:'
                    '${_androidTunnelController.remotePort} via '
                    '${_androidTunnelController.peerId}',
                  ),
                  const Divider(height: 24),
                  _statusRow(
                    'Connection',
                    _androidTunnelController.connectionLabel,
                  ),
                  _statusRow(
                    'Encryption',
                    _androidTunnelController.encryptionLabel,
                  ),
                  _statusRow(
                    'Tunnel mode',
                    _androidTunnelController.tunnelModeLabel,
                  ),
                  _statusRow(
                    'Transport',
                    _androidTunnelController.transportLabel,
                  ),
                  if (_androidTunnelController.peerVersion.isNotEmpty)
                    _statusRow(
                      'Peer version',
                      _androidTunnelController.peerVersion,
                    ),
                  if (_androidTunnelController.hasSecurityWarning) ...[
                    const SizedBox(height: 10),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.warning_amber_rounded),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _androidTunnelController.securityWarning,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _working ? null : (_running ? _stop : _start),
          icon: _working
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(_running ? Icons.stop : Icons.play_arrow),
          label: Text(_running ? 'Stop Tunnel' : 'Start Tunnel'),
        ),
        if (_running) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _openBrowser,
            icon: const Icon(Icons.open_in_browser),
            label: const Text('Open in Browser'),
          ),
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(
                ClipboardData(text: _androidTunnelController.localUrl),
              );
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Local URL copied')),
                );
              }
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copy Local URL'),
          ),
        ],
        const SizedBox(height: 18),
        const Text(
          'The remote host is resolved from the RustDesk-controlled device. '
          'For example, remote host 192.168.1.20:8080 can be opened on this '
          'phone through http://127.0.0.1:18080.',
        ),
      ],
    );
  }

  Widget _statusRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(
            width: 105,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required String hint,
    required bool enabled,
    TextInputType? keyboardType,
    bool obscureText = false,
    bool numbersOnly = false,
    Widget? suffixIcon,
    String? helperText,
    ValueChanged<String>? onSubmitted,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        controller: controller,
        enabled: enabled,
        keyboardType: keyboardType,
        obscureText: obscureText,
        inputFormatters:
            numbersOnly ? [FilteringTextInputFormatter.digitsOnly] : null,
        onSubmitted: onSubmitted,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          helperText: helperText,
          border: const OutlineInputBorder(),
          suffixIcon: suffixIcon,
        ),
      ),
    );
  }

  Future<void> _start() async {
    final peer = _peerId.text.replaceAll(' ', '').trim();
    final host = _remoteHost.text.trim();
    final localPort = int.tryParse(_localPort.text.trim());
    final remotePort = int.tryParse(_remotePort.text.trim());

    if (peer.isEmpty) {
      _error('RustDesk ID is required.');
      return;
    }
    if (host.isEmpty) {
      _error('Remote host is required.');
      return;
    }
    if (localPort == null || localPort < 1024 || localPort > 65535) {
      _error('Local port must be between 1024 and 65535.');
      return;
    }
    if (remotePort == null || remotePort < 1 || remotePort > 65535) {
      _error('Remote port must be between 1 and 65535.');
      return;
    }

    setState(() => _working = true);
    try {
      await _androidTunnelController.start(
        peerId: peer,
        password: _password.text,
        localPort: localPort,
        remoteHost: host,
        remotePort: remotePort,
      );
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Tunnel listening on http://127.0.0.1:$localPort',
            ),
          ),
        );
      }
    } catch (e) {
      _error('Failed to start tunnel: $e');
    } finally {
      if (mounted) {
        setState(() => _working = false);
      }
    }
  }

  Future<void> _stop() async {
    setState(() => _working = true);
    try {
      await _androidTunnelController.stop();
      if (mounted) {
        setState(() {});
      }
    } finally {
      if (mounted) {
        setState(() => _working = false);
      }
    }
  }

  Future<void> _openBrowser() async {
    final url = _androidTunnelController.localUrl;
    if (url.isEmpty) return;
    final ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!ok) {
      _error('Unable to open $url');
    }
  }

  void _error(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }
}
