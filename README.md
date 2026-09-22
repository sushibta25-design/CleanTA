# CleanTA 0.1.2 — bản thử Dopamine rootless

Nút **CT** trên CarPlay mở bảng ứng dụng đang có tiến trình. Có thể kéo nút CT đến vị trí khác. Chọn ứng dụng → **Đóng ứng dụng**. CleanTA yêu cầu SpringBoard kết thúc ứng dụng, kiểm tra ở giây 1 và 3 trước khi báo kết quả.

Đây là tweak, chưa phải ứng dụng có icon riêng trên lưới CarPlay. Mục tiêu kiểm thử: iOS 15–16, Dopamine rootless. Chưa xác minh trên thiết bị thật. Không dành cho iPhone chưa jailbreak hoặc bản roothide.

## Cài thử

GitHub → Actions → Build CleanTA rootless → lần chạy xanh → tải artifact `CleanTA-0.1.2-rootless`, giải nén, cài `.deb` bằng Sileo/Filza rồi respring. Kết nối lại CarPlay nếu nút CT chưa xuất hiện.

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
- Không có timer lặp, GPS, mạng, log file hoặc hook cảm ứng toàn hệ thống. Chỉ đọc danh sách theo yêu cầu; có hai lần kiểm tra và một timeout cho mỗi lệnh đóng.

## Kỹ thuật và giới hạn

UIKit overlay passthrough trong CarPlayApp; `LSApplicationWorkspace` liệt kê proxy; `FBSSystemService` đọc PID và gửi yêu cầu kết thúc từ SpringBoard. Darwin notify truyền khóa gồm hash bundle + PID; server tự duyệt lại app hợp lệ, không nhận PID rồi kill trực tiếp. Đổi PID giữa lúc liệt kê và đóng sẽ bị từ chối. Đây không phải kênh IPC có xác thực: tiến trình khác trên thiết bị có thể phát notification. Không dùng nó để mở rộng thành API quản trị thiết bị hoặc đóng daemon.

Mã của ba dự án ConnectTA/MultiTA/Bubble không được thay đổi. Không thêm dependency RocketBootstrap/MRYIPC.

Build: `THEOS=/path/to/theos make package FINALPACKAGE=1` với iOS SDK 16.5. CI build arm64 + arm64e và chạy test kiểm tra đóng gói PID/hash/trạng thái. CI xanh chỉ chứng minh build thành công, không chứng minh private API/CarPlay hoạt động trên máy thật.

## Sửa trong 0.1.1

Cửa sổ phủ gắn trực tiếp vào UIScreen CarPlay, không gắn vào UIWindowScene đầu tiên (có thể là dock). Kích thước lấy từ screen.coordinateSpace, cập nhật khi mở bảng/đổi mode màn hình. Giao diện nền tối với màu chữ và nút xác định rõ. Ngắt màn hình sẽ giải phóng overlay, kết nối lại tạo mới. Cần kiểm tra thực tế toàn màn và thao tác đóng VML; cơ chế đóng ứng dụng giữ nguyên.

## Kiểm tra trong 0.1.2

Giữ nguyên cơ chế gửi lệnh đóng. Hiện tên ứng dụng, PID trước lệnh và kết quả tại giây 1/3. SpringBoard đối chiếu PID do FrontBoard trả về với `kill(pid, 0)` (chỉ thăm dò tồn tại, không gửi tín hiệu đóng). Nếu API còn trả PID cũ nhưng kernel báo ESRCH, có thể xác nhận tiến trình cũ đã mất. EPERM được xem là còn tồn tại, không phải đã đóng; lỗi đọc không được báo thành công. PID mới còn tồn tại được ghi “Có tiến trình mới”. Không có vòng lặp buộc tắt app.

Ảnh Google Maps còn trên MultiTA không đủ để kết luận app đang chạy: có thể là nội dung được giữ lại hoặc app đã được mở lại. CleanTA chưa gỡ scene của MultiTA. Sau khi đóng, chụp dòng tên/PID/1s/3s, đừng bấm Làm mới trước khi chụp vì nút đó thay dòng trạng thái. Kiểm tra chỉ phản ánh hai thời điểm, không ngăn mở lại sau đó. Kernel probe PID không xác minh thời điểm tạo process; tái sử dụng PID có thể dẫn tới báo chưa đóng (không tự gửi tín hiệu tới PID đó).


## 0.1.3 diagnostic build

Tap **Log 60s**, then close Google Maps once (CleanTA or swipe on the iPhone).
Wait 60 seconds without reopening Maps. In Filza send the entire folder
`/var/mobile/Library/Logs/CleanTA` (SpringBoard.log, CarPlay.log and any .log.1).
The log button works without selecting/closing an app. Closing with CleanTA also
starts a 60-second trace in each participating process. Repeated presses extend it.

Logs include version, wall-clock timestamp, local process ID, request key,
termination request/return, original/current PID kernel probes at 1 and 3 seconds,
and process changes polled every 250ms for 60 seconds. Kernel metadata includes
process start time, parent and state when permission permits; errors are explicit.
No polling occurs after the trace expires. Files rotate at 512 KiB per process
with one backup (roughly 2 MiB total, plus one final record per file).

A signature-checked, pass-through observer records FBSSystemService
openApplication:options:withResult: calls in SpringBoard/CarPlay with stack symbols
and option keys only. It does not alter arguments or callbacks. This is partial
coverage: other APIs, runningboardd/carplayd, and other processes are not hooked.
**No OPEN_REQUEST does not prove that no launch occurred, and PPID does not identify
the requesting app/tweak.** The startup record states whether the hook installed.
No URLs, location values, or application content are deliberately collected.

This is a diagnostic build, not a confirmed fix for relaunch. The close mechanism
is unchanged. Refresh now omits PIDs known to be absent in the kernel and visibly
acknowledges completion; permission-unknown PIDs are retained conservatively.


## 0.1.4 scene diagnostics and result wording

The 60-second trace now also observes DBApplicationSceneViewController foreground,
background and scene-destruction callbacks, FBSceneManager scene creation, and
FBScene/FBSScene settings updates where the runtime class and exact ABI match.
Missing/incompatible methods are logged and skipped; installation is retried on
trace start for classes loaded late. All original calls/arguments/callbacks pass
through unchanged. Maximum 300 scene events per trace per process, with stack
symbols and selected object identifiers (no settings values). All scene events
are included during this short trace, including other apps, to avoid losing
activation paths where the target bundle is not directly available.
Loaded jailbreak image filenames help verify which tweaks actually loaded in
SpringBoard/CarPlay. Presence of an image or nearby scene event alone does not
establish causation. Other processes/APIs remain outside observer coverage.

Results distinguish confirmed old PID exit from verified full stop and a new PID.
API -1 plus an absent old PID now says the old process closed, current process
unknown; it is NOT interpreted as proof the app cannot be running. The old row
is removed in this case; Refresh can rediscover a process later. A confirmed new
PID replaces the stale row immediately. The termination mechanism is unchanged.
