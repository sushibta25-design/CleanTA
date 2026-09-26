# CleanTA 0.1

Đóng ứng dụng đang chạy từ màn hình CarPlay. iOS 15–16, Dopamine rootless.

- Mở bằng icon **CleanTA** trên Home CarPlay (cần tweak bridge kiểu CarBridge để hiện app lên CarPlay).
- Danh sách hiện icon, tên và bundle ID của từng ứng dụng đang mở. Chạm vào ứng dụng để đóng.
- **Đóng tất cả** đóng lần lượt từng ứng dụng.
- **Xong**: đóng bảng và kết thúc app CleanTA để CarPlay về Home.
- App dẫn đường (VIETMAP LIVE, Google Maps…): CleanTA gỡ scene CarPlay và chặn CarPlay tự mở lại trong 5 giây, sau đó mở lại bình thường.
- Chỉ đóng app người dùng và Maps/Music/Podcasts của Apple. Không đóng tiến trình hệ thống.

Build: `THEOS=/path/to/theos make package FINALPACKAGE=1` với iOS SDK 16.5.
