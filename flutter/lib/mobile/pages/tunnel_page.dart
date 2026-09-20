import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/autocomplete.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:url_launcher/url_launcher.dart';

import 'home_page.dart';

final _androidTunnelController = AndroidTunnelController();

class _TunnelForward {
  final int localPort;
  final String remoteHost;
  final int remotePort;

  const _TunnelForward({
    required this.localPort,
    required this.remoteHost,
    required this.remotePort,
  });

  factory _TunnelForward.fromJson(List<dynamic> json) {
    return _TunnelForward(
      localPort: json[0] as int,
      remoteHost: json[1] as String,
      remotePort: json[2] as int,
    );
  }

  bool sameEndpoint(_TunnelForward other) =>
      localPort == other.localPort &&
      remoteHost == other.remoteHost &&
      remotePort == other.remotePort;
}

class AndroidTunnelController extends ChangeNotifier {
  FFI? _ffi;
  bool running = false;
  String peerId = '';
  List<_TunnelForward> forwards = <_TunnelForward>[];
  bool? secure;
  bool? direct;
  bool? mux;
  String streamType = '';
  String peerVersion = '';

  String localUrl(_TunnelForward forward) =>
      'http://127.0.0.1:${forward.localPort}';

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
    required List<_TunnelForward> forwards,
  }) async {
    if (running) {
      await stop();
    }
    if (forwards.isEmpty) {
      throw StateError('At least one port forward is required');
    }

    final ffi = FFI(null, forceUniqueSession: true);
    _ffi = ffi;
    _resetStatus();
    ffi.ffiModel.addListener(_syncStatus);
    this.peerId = peerId;
    this.forwards = List<_TunnelForward>.unmodifiable(forwards);

    try {
      // Match the normal connection page: let RustDesk resolve any remembered
      // PeerConfig/address-book password itself. If none is available, the
      // existing input-password / re-input-password / 2FA dialogs are used.
      ffi.start(
        peerId,
        isPortForward: true,
      );

      // Reconcile the mobile list with RustDesk's native per-peer
      // PeerConfig.port_forwards. Existing unchanged mappings are already
      // started by the port-forward session; changed/new mappings are updated
      // dynamically through the same API used by the desktop tunnel page.
      final desiredByPort = <int, _TunnelForward>{
        for (final forward in forwards) forward.localPort: forward,
      };
      try {
        final peer = bind.mainGetPeerSync(id: peerId);
        final config = jsonDecode(peer) as Map<String, dynamic>;
        final existingJson =
            (config['port_forwards'] as List<dynamic>? ?? const <dynamic>[]);
        final existing = <_TunnelForward>[];

        for (final item in existingJson) {
          if (item is List &&
              item.length >= 3 &&
              item[0] is int &&
              item[1] is String &&
              item[2] is int) {
            existing.add(_TunnelForward.fromJson(item));
          }
        }

        for (final saved in existing) {
          final desired = desiredByPort[saved.localPort];
          if (desired == null || !saved.sameEndpoint(desired)) {
            await bind.sessionRemovePortForward(
              sessionId: ffi.sessionId,
              localPort: saved.localPort,
            );
          }
        }
      } catch (e) {
        debugPrint('Failed to reconcile saved tunnel mappings: $e');
      }

      for (final forward in forwards) {
        await bind.sessionAddPortForward(
          sessionId: ffi.sessionId,
          localPort: forward.localPort,
          remoteHost: forward.remoteHost,
          remotePort: forward.remotePort,
        );
      }

      final ok = await ffi.invokeMethod(
        'start_tunnel_service',
        {
          'description':
              '${forwards.length} TCP port(s) via RustDesk peer $peerId',
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
    // Closing the session stops all listeners. Do not remove port forwards
    // here: they are RustDesk's persisted per-peer tunnel configuration and
    // should be available the next time this peer is selected.
    await _closeSession();
    running = false;
    peerId = '';
    forwards = <_TunnelForward>[];
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
  TunnelPage({super.key});

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
  final _peerFocusNode = FocusNode();
  final AllPeersLoader _allPeersLoader = AllPeersLoader();

  List<_TunnelForward> _forwards = <_TunnelForward>[];
  bool _working = false;
  bool _loadingSavedPeer = false;
  String _loadedPeerId = '';

  bool get _running => _androidTunnelController.running;

  @override
  void initState() {
    super.initState();
    _allPeersLoader.init(setState);
    if (_running) {
      _peerId.text = _androidTunnelController.peerId;
      _loadedPeerId = _androidTunnelController.peerId;
      _forwards = List<_TunnelForward>.from(_androidTunnelController.forwards);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await _allPeersLoader.getAllPeers();
        await _loadLastSavedPeer();
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
      await _selectPeer(id);
    } catch (e) {
      debugPrint('Failed to load last saved peer for tunnel: $e');
    } finally {
      _loadingSavedPeer = false;
    }
  }

  Future<void> _selectPeer(String peerId) async {
    final id = peerId.replaceAll(' ', '').trim();
    if (id.isEmpty || _running) return;

    _peerId.text = id;
    _loadedPeerId = id;
    _loadSavedTunnelsForPeer(id);
    if (mounted) {
      setState(() {});
    }
  }

  void _loadSavedTunnelsForPeer(String peerId) {
    final result = <_TunnelForward>[];
    try {
      final peer = bind.mainGetPeerSync(id: peerId);
      final config = jsonDecode(peer) as Map<String, dynamic>;
      final existing =
          (config['port_forwards'] as List<dynamic>? ?? const <dynamic>[]);
      for (final item in existing) {
        if (item is List &&
            item.length >= 3 &&
            item[0] is int &&
            item[1] is String &&
            item[2] is int) {
          result.add(_TunnelForward.fromJson(item));
        }
      }
    } catch (e) {
      debugPrint('Failed to load saved tunnel mappings for $peerId: $e');
    }
    result.sort((a, b) => a.localPort.compareTo(b.localPort));
    _forwards = result;
  }

  void _onTunnelStatusChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _androidTunnelController.removeListener(_onTunnelStatusChanged);
    _allPeersLoader.clear();
    _peerId.dispose();
    _peerFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final disabled = _working || _running;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
      children: [
        _buildPeerSelector(disabled),
        const SizedBox(height: 18),
        _buildForwardHeader(disabled),
        const SizedBox(height: 8),
        if (_forwards.isEmpty)
          _buildEmptyForwardCard()
        else
          ..._forwards.asMap().entries.map(
                (entry) => _buildForwardCard(
                  entry.key,
                  entry.value,
                  disabled,
                ),
              ),
        if (_running) ...[
          const SizedBox(height: 12),
          _buildStatusCard(),
        ],
        const SizedBox(height: 16),
        SizedBox(
          height: 48,
          child: ElevatedButton.icon(
            onPressed: _working
                ? null
                : (_running
                    ? _stop
                    : (_forwards.isEmpty ? null : _start)),
            icon: _working
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(_running ? Icons.stop : Icons.play_arrow),
            label: Text(_running ? 'Stop Tunnel' : 'Start Tunnel'),
          ),
        ),
      ],
    );
  }

  Widget _buildPeerSelector(bool disabled) {
    return Ink(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: const BorderRadius.all(Radius.circular(13)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 16),
              child: TextField(
                controller: _peerId,
                focusNode: _peerFocusNode,
                enabled: !disabled,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.visiblePassword,
                decoration: InputDecoration(
                  labelText: translate('Remote ID'),
                  border: InputBorder.none,
                ),
                onChanged: (value) {
                  final id = value.replaceAll(' ', '').trim();
                  if (id != _loadedPeerId) {
                    setState(() {
                      _loadedPeerId = id;
                      _forwards = <_TunnelForward>[];
                    });
                  }
                },
                onSubmitted: _selectPeer,
              ),
            ),
          ),
          IconButton(
            tooltip: translate('Remote ID'),
            onPressed: disabled ? null : _showPeerPicker,
            icon: const Icon(Icons.arrow_drop_down),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _buildForwardHeader(bool disabled) {
    return Row(
      children: [
        Expanded(
          child: Text(
            translate('TCP tunneling'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        TextButton.icon(
          onPressed: disabled ? null : () => _editForward(),
          icon: const Icon(Icons.add),
          label: Text(translate('Add')),
        ),
      ],
    );
  }

  Widget _buildEmptyForwardCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        child: Column(
          children: [
            Icon(
              Icons.swap_horiz,
              size: 32,
              color: Theme.of(context).disabledColor,
            ),
            const SizedBox(height: 8),
            Text(
              'No port forwards configured',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildForwardCard(
      int index, _TunnelForward forward, bool disabled) {
    final localUrl = _androidTunnelController.localUrl(forward);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Row(
          children: [
            const Icon(Icons.lan_outlined),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '127.0.0.1:${forward.localPort}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      const Icon(Icons.arrow_forward, size: 14),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          '${forward.remoteHost}:${forward.remotePort}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (_running) ...[
              IconButton(
                tooltip: 'Open in Browser',
                onPressed: () => _openBrowser(localUrl),
                icon: const Icon(Icons.open_in_browser),
              ),
              IconButton(
                tooltip: 'Copy Local URL',
                onPressed: () => _copyUrl(localUrl),
                icon: const Icon(Icons.copy),
              ),
            ] else ...[
              IconButton(
                tooltip: translate('Edit'),
                onPressed: disabled ? null : () => _editForward(index: index),
                icon: const Icon(Icons.edit_outlined),
              ),
              IconButton(
                tooltip: translate('Delete'),
                onPressed: disabled ? null : () => _removeForward(index),
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    return Card(
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
                  translate('Listening ...'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${_forwards.length} port(s) via ${_androidTunnelController.peerId}',
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
                    child: Text(_androidTunnelController.securityWarning),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
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

  Future<void> _showPeerPicker() async {
    FocusScope.of(context).unfocus();
    if (_allPeersLoader.needLoad) {
      await _allPeersLoader.getAllPeers();
    }
    if (!mounted) return;

    final search = TextEditingController();
    var query = '';

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final normalized = query.trim().toLowerCase();
            final peers = _allPeersLoader.peers.where((peer) {
              if (normalized.isEmpty) return true;
              return peer.id.toLowerCase().contains(normalized) ||
                  peer.alias.toLowerCase().contains(normalized) ||
                  peer.hostname.toLowerCase().contains(normalized) ||
                  peer.username.toLowerCase().contains(normalized);
            }).toList();

            return FractionallySizedBox(
              heightFactor: 0.78,
              child: SafeArea(
                top: false,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                      child: TextField(
                        controller: search,
                        autofocus: false,
                        decoration: InputDecoration(
                          hintText: translate('Remote ID'),
                          prefixIcon: const Icon(Icons.search),
                        ),
                        onChanged: (value) {
                          setSheetState(() => query = value);
                        },
                        onSubmitted: (value) {
                          final id = value.replaceAll(' ', '').trim();
                          if (id.isEmpty) return;
                          Navigator.of(sheetContext).pop();
                          _selectPeer(id);
                        },
                      ),
                    ),
                    Expanded(
                      child: peers.isEmpty
                          ? Center(
                              child: Text(
                                'No saved device matches. Enter an ID above.',
                              ),
                            )
                          : ListView.builder(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 12),
                              itemCount: peers.length,
                              itemBuilder: (context, index) {
                                final peer = peers[index];
                                return AutocompletePeerTile(
                                  peer: peer,
                                  onSelect: () {
                                    Navigator.of(sheetContext).pop();
                                    _selectPeer(peer.id);
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    search.dispose();
  }

  Future<void> _editForward({int? index}) async {
    final editing = index == null ? null : _forwards[index];
    final localPort = TextEditingController(
      text: editing?.localPort.toString() ?? '',
    );
    final remoteHost = TextEditingController(
      text: editing?.remoteHost ?? '192.168.1.1',
    );
    final remotePort = TextEditingController(
      text: editing?.remotePort.toString() ?? '',
    );

    final result = await showModalBottomSheet<_TunnelForward>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            4,
            20,
            20 + MediaQuery.of(sheetContext).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                editing == null ? translate('Add') : translate('Edit'),
                style: Theme.of(sheetContext).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: localPort,
                autofocus: editing == null,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                ],
                decoration: InputDecoration(
                  labelText: translate('Local Port'),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: remoteHost,
                decoration: InputDecoration(
                  labelText: translate('Remote Host'),
                  hintText: '192.168.1.100',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: remotePort,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                ],
                decoration: InputDecoration(
                  labelText: translate('Remote Port'),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: ElevatedButton(
                  onPressed: () {
                    final lp = int.tryParse(localPort.text.trim());
                    final host = remoteHost.text.trim();
                    final rp = int.tryParse(remotePort.text.trim());

                    if (lp == null || lp < 1024 || lp > 65535) {
                      _sheetError(
                        sheetContext,
                        'Local port must be between 1024 and 65535.',
                      );
                      return;
                    }
                    if (host.isEmpty) {
                      _sheetError(sheetContext, 'Remote host is required.');
                      return;
                    }
                    if (rp == null || rp < 1 || rp > 65535) {
                      _sheetError(
                        sheetContext,
                        'Remote port must be between 1 and 65535.',
                      );
                      return;
                    }

                    final duplicate = _forwards.asMap().entries.any(
                          (entry) =>
                              entry.key != index &&
                              entry.value.localPort == lp,
                        );
                    if (duplicate) {
                      _sheetError(
                        sheetContext,
                        'Local port $lp is already configured.',
                      );
                      return;
                    }

                    Navigator.of(sheetContext).pop(
                      _TunnelForward(
                        localPort: lp,
                        remoteHost: host,
                        remotePort: rp,
                      ),
                    );
                  },
                  child: Text(editing == null ? translate('Add') : 'Save'),
                ),
              ),
            ],
          ),
        );
      },
    );

    localPort.dispose();
    remoteHost.dispose();
    remotePort.dispose();

    if (result == null || !mounted) return;
    setState(() {
      if (index == null) {
        _forwards.add(result);
      } else {
        _forwards[index] = result;
      }
      _forwards.sort((a, b) => a.localPort.compareTo(b.localPort));
    });
  }

  void _removeForward(int index) {
    setState(() {
      _forwards.removeAt(index);
    });
  }

  void _sheetError(BuildContext context, String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  Future<void> _start() async {
    final peer = _peerId.text.replaceAll(' ', '').trim();
    if (peer.isEmpty) {
      _error('RustDesk ID is required.');
      return;
    }
    // A manually typed saved ID may not have been submitted yet. If there is
    // no edited mapping list, give it one last chance to load that peer's
    // native saved port_forwards before rejecting the start.
    if (_forwards.isEmpty) {
      _loadSavedTunnelsForPeer(peer);
      if (mounted) {
        setState(() {});
      }
    }
    if (_forwards.isEmpty) {
      _error('Add at least one port forward.');
      return;
    }

    setState(() => _working = true);
    try {
      await _androidTunnelController.start(
        peerId: peer,
        forwards: List<_TunnelForward>.from(_forwards),
      );
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Tunnel is listening on ${_forwards.length} local port(s).',
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

  Future<void> _openBrowser(String url) async {
    final ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!ok) {
      _error('Unable to open $url');
    }
  }

  Future<void> _copyUrl(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Local URL copied')),
    );
  }

  void _error(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }
}
