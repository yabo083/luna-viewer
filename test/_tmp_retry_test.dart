import 'package:chatluna_mobile/core/model/models.dart';
import 'package:chatluna_mobile/features/chat/message_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(List<PlatformMedia> media) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: MessageView(
        message: ChatMessage(
          id: 'm1',
          role: 'assistant',
          blocks: const [ChatBlock('text', {'text': 'hi'})],
        ),
        base: Uri.parse('http://127.0.0.1:3000'),
        headers: const <String, String>{},
        noticeOpen: <String, bool>{},
        media: media,
      ),
    ),
  ),
);

void main() {
  testWidgets('single image failure offers retry and retries once by itself', (tester) async {
    await tester.pumpWidget(
      _app(const [PlatformMedia(kind: 'image', url: 'http://127.0.0.1:3000/files/a.png')]),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('图片加载失败 · 点击重试'), findsOneWidget);
    debugPrint('--- failure shown ---');

    // 2s 后自动重试一次：转圈出现，再失败又回到手动重试态。
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 100));
    debugPrint('--- after auto retry: ${find.text('图片加载失败 · 点击重试').evaluate().length} ---');

    // 手动点一次。
    await tester.tap(find.text('图片加载失败 · 点击重试'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('图片加载失败 · 点击重试'), findsOneWidget);
    debugPrint('--- manual retry ok ---');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('grid cell failure offers retry', (tester) async {
    await tester.pumpWidget(
      _app(const [
        PlatformMedia(kind: 'image', url: 'http://127.0.0.1:3000/files/a.png'),
        PlatformMedia(kind: 'image', url: 'http://127.0.0.1:3000/files/b.png'),
      ]),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('图片加载失败\n点击重试'), findsNWidgets(2));
    await tester.tap(find.text('图片加载失败\n点击重试').first);
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('undecodable data uri reports decode failure without retry', (tester) async {
    await tester.pumpWidget(
      _app(const [PlatformMedia(kind: 'image', url: 'data:image/png;base64,zzzz')]),
    );
    await tester.pump();
    expect(find.text('无法解码'), findsOneWidget);
  });
}
