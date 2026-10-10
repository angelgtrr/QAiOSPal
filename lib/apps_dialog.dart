import 'package:flutter/material.dart';

import 'apk_tools.dart';

/// Save an installed app from the connected Android device, or install a saved one onto it.
class AppsDialog extends StatefulWidget {
  final String serial;
  final void Function(String) say;
  const AppsDialog({super.key, required this.serial, required this.say});

  @override
  State<AppsDialog> createState() => _AppsDialogState();
}

class _AppsDialogState extends State<AppsDialog> {
  final _filter = TextEditingController();
  List<String> _packages = [];
  List<SavedApk> _saved = [];
  bool _system = false;
  bool _loading = true;
  String? _busy;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final packages = await ApkTools.listPackages(widget.serial, includeSystem: _system);
      final saved = await ApkTools.listSaved();
      if (mounted) {
        setState(() {
          _packages = packages;
          _saved = saved;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _run(String label, Future<String> Function() action) async {
    setState(() => _busy = label);
    widget.say('$label...');
    try {
      widget.say(await action());
    } catch (e) {
      widget.say('$label failed: $e');
    } finally {
      if (mounted) setState(() => _busy = null);
      if (mounted) {
        final saved = await ApkTools.listSaved();
        if (mounted) setState(() => _saved = saved);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final filter = _filter.text.trim().toLowerCase();
    final packages = _packages.where((p) => p.toLowerCase().contains(filter)).toList();
    return Dialog(
      child: SizedBox(
        width: 620,
        height: 560,
        child: DefaultTabController(
          length: 2,
          child: Column(
            children: [
              TabBar(tabs: [Tab(text: 'Save from device (${_packages.length})'), Tab(text: 'Saved APKs (${_saved.length})')]),
              if (_busy != null) const LinearProgressIndicator(),
              Expanded(
                child: TabBarView(
                  children: [
                    Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _filter,
                                  onChanged: (_) => setState(() {}),
                                  decoration: const InputDecoration(labelText: 'Filter packages', isDense: true, prefixIcon: Icon(Icons.search)),
                                ),
                              ),
                              const SizedBox(width: 12),
                              FilterChip(
                                label: const Text('System apps'),
                                selected: _system,
                                onSelected: (v) {
                                  _system = v;
                                  _load();
                                },
                              ),
                              IconButton(tooltip: 'Reload', onPressed: _load, icon: const Icon(Icons.refresh)),
                            ],
                          ),
                        ),
                        Expanded(
                          child: _loading
                              ? const Center(child: CircularProgressIndicator())
                              : _error != null
                                  ? Center(child: Text(_error!))
                                  : ListView.builder(
                                      itemCount: packages.length,
                                      itemBuilder: (_, i) => ListTile(
                                        dense: true,
                                        title: Text(packages[i]),
                                        trailing: TextButton.icon(
                                          onPressed: _busy != null
                                              ? null
                                              : () => _run('Saving ${packages[i]}', () async {
                                                    final apk = await ApkTools.save(widget.serial, packages[i]);
                                                    return 'Saved ${apk.files.length} APK file(s) to ${apk.dir.path}';
                                                  }),
                                          icon: const Icon(Icons.download, size: 18),
                                          label: const Text('Save'),
                                        ),
                                      ),
                                    ),
                        ),
                      ],
                    ),
                    _saved.isEmpty
                        ? Center(child: Text('Nothing saved yet in ${ApkTools.saveRoot().path}', textAlign: TextAlign.center))
                        : ListView.builder(
                            itemCount: _saved.length,
                            itemBuilder: (_, i) => ListTile(
                              dense: true,
                              title: Text(_saved[i].name),
                              subtitle: Text('${_saved[i].files.length} file(s)'),
                              trailing: TextButton.icon(
                                onPressed: _busy != null
                                    ? null
                                    : () => _run('Installing ${_saved[i].name}', () async {
                                          await ApkTools.install(widget.serial, _saved[i]);
                                          return 'Installed ${_saved[i].name} on ${widget.serial}';
                                        }),
                                icon: const Icon(Icons.upload, size: 18),
                                label: const Text('Install here'),
                              ),
                            ),
                          ),
                  ],
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
