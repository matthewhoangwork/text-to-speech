# Lazy Speech Tool

Desktop app (macOS + Windows) tạo audio từ text bằng Edge TTS. Mỗi dòng một
đoạn — paste vào là thấy preview realtime, bấm Tạo audio, nghe thử rồi tải
từng file MP3 hoặc tải tất cả trong 1 file zip.

Tải bản mới nhất ở [Releases](https://github.com/matthewhoangwork/text-to-speech/releases)
(`LazySpeechTool-macOS-arm64.dmg` cho Mac, `LazySpeechTool-Windows-x64.zip`
cho Win — giải nén chạy file exe, không cần cài đặt).

## Tính năng

- Mỗi dòng = 1 đoạn, tự động chọn giọng Anh (`en-US-AriaNeural`) / Việt
  (`vi-VN-HoaiMyNeural`) theo dấu câu
- Xem trước số đoạn realtime khi gõ, nút tải mờ cho đến khi tạo xong
- Tên file `1 - Hello.mp3`, nghe thử từng đoạn, tải zip tất cả
- Không backend, không key — gọi thẳng Edge TTS endpoint, port từ
  [edge-tts](https://github.com/rany2/edge-tts) sang Dart thuần
  (`lib/edge_tts.dart`, dùng `SecureSocket` + WS framing tay vì `dart:io`
  tự chèn User-Agent lạ làm Edge trả 403)

## Dev

```bash
fvm flutter pub get
fvm flutter run -d macos    # hoặc -d windows
fvm flutter test
fvm flutter build macos --release
flutter build windows --release   # chạy trên máy Windows
```

## Release

- Merge vào `main` → CI build `.dmg` + `.zip`, gắn vào release `latest`
- Ra bản mới: bump `version` trong `pubspec.yaml`, rồi
  `git tag vX.Y.Z && git push origin vX.Y.Z` — CI tự đăng release
