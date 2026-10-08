import 'dart:io';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:native_dio_adapter_desktop/native_dio_adapter_desktop.dart';

import 'smoke_test.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (args.contains('--smoke-test')) {
    runZonedGuarded(
      () async {
        try {
          await runSmokeTests().timeout(const Duration(minutes: 2));
          await Future<void>.delayed(const Duration(milliseconds: 300));
          stdout.writeln('Native desktop smoke tests passed.');
          exit(0);
        } catch (error, stack) {
          stderr.writeln('$error\n$stack');
          exit(1);
        }
      },
      (error, stack) {
        stderr.writeln('Unhandled asynchronous error: $error\n$stack');
        exit(1);
      },
    );
    return;
  }
  runApp(const MaterialApp(home: ExamplePage()));
}

class ExamplePage extends StatefulWidget {
  const ExamplePage({super.key});
  @override
  State<ExamplePage> createState() => _ExamplePageState();
}

class _ExamplePageState extends State<ExamplePage> {
  final _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
      responseType: ResponseType.plain,
    ),
  )..httpClientAdapter = NativeDesktopAdapter();
  String _result =
      'Press Request to fetch https://example.com with native TLS.';
  bool _loading = false;

  Future<void> _request() async {
    setState(() => _loading = true);
    try {
      final response = await _dio.get<String>('https://example.com');
      if (mounted) {
        setState(() => _result = '${response.statusCode}\n${response.data}');
      }
    } catch (error) {
      if (mounted) setState(() => _result = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _dio.close(force: true);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Native Dio Desktop')),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FilledButton(
            onPressed: _loading ? null : _request,
            child: Text(_loading ? 'Requesting…' : 'Request'),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: SingleChildScrollView(child: SelectableText(_result)),
          ),
        ],
      ),
    ),
  );
}
