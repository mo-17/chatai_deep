import 'package:flutter/material.dart';
import 'package:hi_download/hi_download.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'hi_download example',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1976D2)),
        useMaterial3: true,
      ),
      home: const DownloadPage(),
    );
  }
}

class DownloadPage extends StatefulWidget {
  const DownloadPage({super.key});

  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage> {
  final _urlCtrl = TextEditingController(
    text: 'https://flutter.github.io/assets-for-api-docs/assets/widgets/owl.jpg',
  );
  final _fileNameCtrl = TextEditingController(text: 'demo.jpg');

  int _total = 0;
  int _received = 0;
  bool _busy = false;
  bool _done = false;
  String? _savedPath;
  String? _error;

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _done = false;
      _total = 0;
      _received = 0;
      _savedPath = null;
      _error = null;
    });
    try {
      final path = await HiDownLoad().download(
        downLoadUrl: _urlCtrl.text.trim(),
        fileName: _fileNameCtrl.text.trim(),
        listener: (total, received, done) {
          if (!mounted) return;
          setState(() {
            _total = total;
            _received = received;
            _done = done;
            if (done) _busy = false;
          });
        },
      );
      if (mounted) setState(() => _savedPath = path);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _busy = false;
        });
      }
    }
  }

  double get _progress => _total > 0 ? _received / _total : 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('hi_download · example')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _urlCtrl,
                decoration: const InputDecoration(
                  labelText: 'Download URL',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _fileNameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Save as (filename)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _busy ? null : _start,
                icon: const Icon(Icons.download),
                label: Text(_busy ? 'Downloading…' : 'Start download'),
              ),
              const SizedBox(height: 20),
              if (_total > 0 || _busy) ...[
                LinearProgressIndicator(value: _total == 0 ? null : _progress),
                const SizedBox(height: 8),
                Text(
                  _total == 0
                      ? 'Connecting…'
                      : '${(_progress * 100).toStringAsFixed(1)}%  '
                          '($_received / $_total bytes)',
                  style: const TextStyle(fontSize: 13),
                ),
              ],
              if (_done && _savedPath != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    border: Border.all(color: Colors.green.shade300),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('✓ Saved to:',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      SelectableText(_savedPath!, style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    border: Border.all(color: Colors.red.shade300),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(_error!,
                      style: TextStyle(color: Colors.red.shade800, fontSize: 12)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
