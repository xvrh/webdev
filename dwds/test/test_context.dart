import 'dart:convert';
import 'dart:io';

import 'package:dwds/src/chrome_proxy_service.dart';
import 'package:dwds/src/helpers.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:webdriver/io.dart';
import 'package:webkit_inspection_protocol/webkit_inspection_protocol.dart';

class TestContext {
  String appUrl;
  ChromeProxyService service;
  WipConnection tabConnection;
  Process webdev;
  WebDriver webDriver;
  Process chromeDriver;
  int port;

  Future<void> setUp() async {
    port = await findUnusedPort();
    try {
      chromeDriver = await Process.start(
          'chromedriver', ['--port=4444', '--url-base=wd/hub']);
    } catch (e) {
      throw StateError(
          'Could not start ChromeDriver. Is it installed?\nError: $e');
    }

    await Process.run('pub', ['global', 'activate', 'webdev']);
    webdev = await Process.start(
        'pub', ['global', 'run', 'webdev', 'serve', 'example:$port']);
    webdev.stderr
        .transform(const Utf8Decoder())
        .transform(const LineSplitter())
        .listen(printOnFailure);
    await webdev.stdout
        .transform(const Utf8Decoder())
        .transform(const LineSplitter())
        .takeWhile((line) => !line.contains('$port'))
        .drain();
    appUrl = 'http://localhost:$port/hello_world/';
    var debugPort = await findUnusedPort();
    webDriver = await createDriver(desired: {
      'chromeOptions': {
        'args': ['remote-debugging-port=$debugPort', '--headless']
      }
    });
    await webDriver.get(appUrl);
    var connection = ChromeConnection('localhost', debugPort);
    var tab = await connection.getTab((t) => t.url == appUrl);
    tabConnection = await tab.connect();
    await tabConnection.runtime.enable();
    await tabConnection.debugger.enable();

    // Check if the app is already loaded, look for the top level
    // `registerExtension` variable which we set as the last step.
    var result = await tabConnection.runtime
        .evaluate('(window.registerExtension !== undefined).toString();');
    if (result.value != 'true') {
      // If it wasn't already loaded, then wait for the 'Page Ready' log.
      await tabConnection.runtime.onConsoleAPICalled.firstWhere((event) =>
          event.type == 'debug' && event.args[0].value == 'Page Ready');
    }

    var assetHandler = (String path) async {
      var result = await http.get('http://localhost:$port/$path');
      return result.body;
    };

    service = await ChromeProxyService.create(
      connection,
      assetHandler,
      // Provided in the example index.html.
      'instance-id-for-testing',
    );
  }

  Future<Null> tearDown() async {
    webdev.kill();
    await webdev.exitCode;
    await webDriver?.quit();
    chromeDriver.kill();
  }
}
