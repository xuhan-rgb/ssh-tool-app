import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_tool_app/services/remote_image_service.dart';

void main() {
  test('finds remote image paths in Markdown and plain replies', () {
    final paths = RemoteImageService.references('''
图像已保存：`/tmp/chart.png`
![结果](images/output%20image.webp)
[查看原图](file:///tmp/chart.png)
参考 https://example.com/logo.png
''');
    expect(paths, ['/tmp/chart.png', 'images/output image.webp']);
  });

  test('does not offer ordinary files or web images as remote images', () {
    expect(
      RemoteImageService.references(
        '[网页](https://example.com/a.png) [报告](/tmp/report.pdf)',
      ),
      isEmpty,
    );
  });

  test('keeps each image next to its reference in a multi-image reply', () {
    const reply = '第一张：`/tmp/first.png`\n比较说明\n第二张：![预览](images/second%20view.webp)';
    final refs = RemoteImageService.inlineReferences(reply);
    expect(refs.map((item) => item.path),
        ['/tmp/first.png', 'images/second view.webp']);
    expect(refs.map((item) => item.embedded), [false, true]);
    expect(reply.substring(0, refs.first.end), '第一张：`/tmp/first.png`');
    expect(reply.substring(refs.first.end, refs.last.end),
        '\n比较说明\n第二张：![预览](images/second%20view.webp)');
  });

  test('plain percent signs in image file names do not break the reply', () {
    final refs = RemoteImageService.inlineReferences(
        '结果：`/tmp/100%完成图.png` 和 `images/50%25-result.webp`');
    expect(refs.map((item) => item.path),
        ['/tmp/100%完成图.png', 'images/50%-result.webp']);
  });

  test('invalid encoded bytes do not break image path parsing', () {
    expect(RemoteImageService.references('`/tmp/%FF-result.png`'),
        ['/tmp/%FF-result.png']);
  });

  test('lists every referenced image without a five-image cutoff', () {
    final paths = RemoteImageService.references(
        List.generate(7, (index) => '`image_$index.png`').join(' '));
    expect(paths, List.generate(7, (index) => 'image_$index.png'));
  });

  test('only Markdown image syntax requests an inline preview', () {
    final refs = RemoteImageService.inlineReferences(
        '`one.png` [原图](two.png) ![结果](three.png)');
    expect(refs.map((item) => item.embedded), [false, false, true]);
  });
}
