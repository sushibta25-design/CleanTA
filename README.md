# CleanTA 0.2.0

Đóng ứng dụng đang chạy từ màn hình CarPlay. iOS 15–16, Dopamine rootless.

- Mở bằng icon **CleanTA** trên Home CarPlay (cần tweak bridge kiểu CarBridge để hiện app lên CarPlay). Nút **CT** nổi vẫn còn làm dự phòng.
- Chạm vào một ứng dụng trong danh sách để đóng. **Đóng tất cả** đóng lần lượt từng app.
- **Xong**: đóng bảng và kết thúc app CleanTA để CarPlay về Home.
- App dẫn đường (VIETMAP LIVE, Google Maps…): CleanTA gỡ scene CarPlay và chặn CarPlay tự mở lại trong 5 giây. Sau đó mở lại bình thường.
- Chỉ đóng app người dùng và Maps/Music/Podcasts của Apple. Không đóng tiến trình hệ thống.

Log gọn (chỉ kết quả đóng app, tối đa 128 KB): `/var/mobile/Library/Logs/CleanTA/`.

Build: `THEOS=/path/to/theos make package FINALPACKAGE=1` với iOS SDK 16.5.
