# CleanTA 0.1.1 — bản thử Dopamine rootless

Nút **CT** trên CarPlay mở bảng ứng dụng đang có tiến trình. Có thể kéo nút CT đến vị trí khác. Chọn ứng dụng → **Đóng ứng dụng**. CleanTA yêu cầu SpringBoard kết thúc ứng dụng, chờ một giây rồi kiểm tra lại trước khi báo đã dừng.

Đây là tweak, chưa phải ứng dụng có icon riêng trên lưới CarPlay. Mục tiêu kiểm thử: iOS 15–16, Dopamine rootless. Chưa xác minh trên thiết bị thật. Không dành cho iPhone chưa jailbreak hoặc bản roothide.

## Cài thử

GitHub → Actions → Build CleanTA rootless → lần chạy xanh → tải artifact `CleanTA-0.1.1-rootless`, giải nén, cài `.deb` bằng Sileo/Filza rồi respring. Kết nối lại CarPlay nếu nút CT chưa xuất hiện.

1. Mở VML và bật tiếng, về Home CarPlay.
2. Bấm CT → chọn VML → Đóng ứng dụng.
3. Kiểm tra tiếng dừng, dòng trạng thái xác nhận, và ứng dụng mở lại từ đầu khi tự mở.
4. Thử CT trong MultiTA, đóng một ứng dụng đang chia màn; quan sát pane còn lại và Home CarPlay.
5. Ngắt/nối lại CarPlay; kiểm tra CT xuất hiện và cảm ứng ngoài nút CT hoạt động bình thường.

Nếu danh sách trống dù VML đang chạy, chụp dòng trạng thái cùng phiên bản iOS. Private API đọc PID có thể bị hạn chế trong CarPlayApp; bản này không khẳng định danh sách trống nghĩa là không có ứng dụng chạy. Nếu báo chưa hỗ trợ, cần kiểm tra private API trên máy thật. Không báo thành công chỉ vì đã gửi lệnh.

## Phạm vi

- Chỉ ứng dụng loại User cùng Apple Maps, Music và Podcasts. Không cho đóng SpringBoard, CarPlayApp hay daemon hệ thống.
- Đóng ứng dụng trên cả iPhone và CarPlay, không chỉ ẩn cửa sổ. Không xoá dữ liệu app hoặc cache; không respring/userspace reboot.
- Không tự đóng hàng loạt; không ngăn iOS/tweak khác mở lại ứng dụng. Thẻ app switcher có thể còn; giao diện MultiTA có thể cần chọn lại app đã đóng.
- Không có timer lặp, GPS, mạng, log file hoặc hook cảm ứng toàn hệ thống. Chỉ đọc danh sách theo yêu cầu; có một lần kiểm tra và một timeout cho mỗi lệnh đóng.

## Kỹ thuật và giới hạn

UIKit overlay passthrough trong CarPlayApp; `LSApplicationWorkspace` liệt kê proxy; `FBSSystemService` đọc PID và gửi yêu cầu kết thúc từ SpringBoard. Darwin notify truyền khóa gồm hash bundle + PID; server tự duyệt lại app hợp lệ, không nhận PID rồi kill trực tiếp. Đổi PID giữa lúc liệt kê và đóng sẽ bị từ chối. Đây không phải kênh IPC có xác thực: tiến trình khác trên thiết bị có thể phát notification. Không dùng nó để mở rộng thành API quản trị thiết bị hoặc đóng daemon.

Mã của ba dự án ConnectTA/MultiTA/Bubble không được thay đổi. Không thêm dependency RocketBootstrap/MRYIPC.

Build: `THEOS=/path/to/theos make package FINALPACKAGE=1` với iOS SDK 16.5. CI build arm64 + arm64e và chạy test kiểm tra đóng gói PID/hash/trạng thái. CI xanh chỉ chứng minh build thành công, không chứng minh private API/CarPlay hoạt động trên máy thật.

## Sửa trong 0.1.1

Cửa sổ phủ gắn trực tiếp vào UIScreen CarPlay, không gắn vào UIWindowScene đầu tiên (có thể là dock). Kích thước lấy từ screen.coordinateSpace, cập nhật khi mở bảng/đổi mode màn hình. Giao diện nền tối với màu chữ và nút xác định rõ. Ngắt màn hình sẽ giải phóng overlay, kết nối lại tạo mới. Cần kiểm tra thực tế toàn màn và thao tác đóng VML; cơ chế đóng ứng dụng giữ nguyên.
