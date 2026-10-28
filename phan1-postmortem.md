Phần 1: Điều tra sự cố


1. Tóm tắt sự cố: Khi đọc bối cảnh các website trên node bị lỗi 502/504 mà đang chạy dịch vụ nginx + PHP + mysql thì em nghĩ đến khả năng backend có vấn đề đầu tiên dựa vào phản xạ mã lỗi. Gặp trường hợp này cần kiểm tra dịch vụ/port backend còn đang chạy không. Qua kiểm tra log trong dữ liệu sự cố access log, toàn bộ các request đến các trang web của khách hàng trên node đều bị lỗi 502. Nguyên nhân gốc rễ là do node bị full disk, mysql báo lỗi không còn chỗ trống để ghi dữ liệu binlog
2. Timeline sự cố:
- Kiểm tra syslog, bắt đầu từ thời điểm Oct 14 00:00:02 ghi nhận log rotate lỗi dài cho đến hôm 20/10 (log cuối cùng vào lúc: Oct 20 00:00:02)
- Bắt đầu từ lúc Oct 20 01:33:04 mysql không ghi được binlog do hết disk -> mysql sập -> nginx gọi xuống không được -> lỗi 502

3. Phân tích nguyên nhân gốc & chuỗi hệ quả:
- Nguyên nhân ban đầu do vào thời điểm Oct 14 00:00:02, access log của nginx không được rotate, lỗi do sai chính tả từ "dailly" trong file `/usr/sbin/logrotate`, do tool `logrotate` này chạy sai nên log trong nginx không được làm mới /var/log/nginx/*.log -> kiểm tra trong file syslog
- Log trong syslog:
```
Oct 14 00:00:01 web-hcm-07 CRON[5198]: (root) CMD (test -x /usr/sbin/logrotate && /usr/sbin/logrotate /etc/logrotate.conf)
Oct 14 00:00:02 web-hcm-07 logrotate[5199]: error: /etc/logrotate.d/nginx:3 unknown option 'dailly' -- ignoring line
Oct 14 00:00:02 web-hcm-07 logrotate[5199]: error: found error in /var/log/nginx/*.log , skipping
```
- Hệ quả là file access log trong nginx càng ngày càng phình to tới ngày 20/10, thời điểm Oct 20 01:32:57 lúc backup site, không còn đủ dung lượng nên tar nén bị lỗi. Khi nén bị lỗi dẫn đến file log backup site chứa mười mấy GB hôm 19/10 không được xóa khiến dung lượng full nhanh và full disk, mysql chết.
- Log trong syslog:
```
Oct 20 01:32:57 web-hcm-07 backup-sites: tar: /var/backups/sites-20261020.tar.gz: Wrote only 4096 of 10240 bytes
Oct 20 01:32:57 web-hcm-07 backup-sites: tar: Error is not recoverable: exiting now
Oct 20 01:32:58 web-hcm-07 backup-sites: ERROR backup failed exit=2, keep old backups
Oct 20 01:33:04 web-hcm-07 mysqld[1187]: [ERROR] [MY-000035] [Server] Disk is full writing './binlog.000187' (OS errno 28 - No space left on device). Waiting for someone to free space... Retry in 60 secs.
```

4. Các giả thuyết đã loại trừ:
- Ban đầu em đã nghi ngờ vấn đề do backend, khi đọc file mysql/error.log thấy báo full disk là có thể biết được nguyên nhân, nhưng root cause bị full disk ban đầu khi đọc syslog đọc ở chỗ rotate error em nhầm là do backup site tại /var/backups/ không được xóa đúng cách, sau khi kiểm tra thấy các file backup site này đều được xóa mỗi ngày thì khi coi kỹ lại ở file du-var trong snapshot chiếm 37G và mới xác định nguyên nhân gốc do access log bị phình ra hằng ngày.

5. Khắc phục tức thời
- Xóa trước file `/var/backups/sites-20261019.tar.gz` trước do trước đó backup site hôm 20/1 bị fail khiến file này không bị xóa. Xóa trước file này và kiểm tra start lại msysql. Lệnh: `rm /var/backups/sites-20261019.tar.gz`.
- Sau đó chạy lại backup hoàn chỉnh cho hôm 20/10 bằng lệnh: /usr/local/bin/backup-sites.sh. Sau khi backup xong hoàn tất thì xóa file backup chưa hoàn chỉnh hôm 20/10 trước đó đi, lệnh: `rm /var/backups/sites-20261020.tar.gz"
- Sau đó chỉnh lại chữ "dailly" thành "daily" trong file logrotate-nginx

6. Phương án phòng ngừa:
- Phòng trường hợp này về sau, nên cấu hình công cụ monitor disk trên server, theo dõi disk sử dụng ổn định, khi lượng disk tăng dần theo từng ngày không thấy giảm và khi chạm mức khoảng 80% nên có alert về kênh telegram/discord để tiện theo dõi.
