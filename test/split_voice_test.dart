import 'package:flutter_test/flutter_test.dart';
import 'package:tts_tool/edge_tts.dart';

void main() {
  test('split ; bo rong + trim', () {
    expect(splitSegments('a; b ;;c;'), ['a', 'b', 'c']);
    expect(splitSegments(''), isEmpty);
    expect(splitSegments(';;;'), isEmpty);
  });

  test('detect voice theo dau tieng Viet', () {
    expect(detectVoice('hello world'), enVoice);
    expect(detectVoice('xin chào bạn'), viVoice);
    expect(detectVoice('Hoc tieng Anh'), enVoice);
    expect(detectVoice('đi học'), viVoice);
  });

  test('sanitize thay control char', () {
    expect(sanitize('a\x07b\x0bc'), 'a b c');
  });

  test('ten file: so thu tu - cau', () {
    expect(fileNameFor(1, 'Hello'), '1 - Hello.mp3');
    expect(fileNameFor(2, 'My name is Matthew'), '2 - My name is Matthew.mp3');
    expect(fileNameFor(3, 'a/b:c*d?e"f<g>h|i'), '3 - abcdefghi.mp3');
    expect(fileNameFor(4, ';;;'), '4 - segment.mp3');
  });
}
