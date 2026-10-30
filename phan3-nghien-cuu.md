Phương án chặn / rate-limit ở tầng L4 (nftables) em đã test với giới hạn SYN:
- Khi set 1 ngưỡng giới hạn SYN cho 1 IP cụ thể, vượt mức sẽ drop gói, khi crawl có thể khiến nó retrans lại gói SYN nhiều lần để giảm tốc độ crawl.
- Tuy nhiên cách này chỉ phù hợp khi có IP chỉ định, chưa phù hợp áp lên cả server vì sẽ khiến ảnh hưởng chung
<img width="900" height="400" alt="image" src="https://github.com/user-attachments/assets/5fba5323-9000-4ba6-abff-e1e3bf2cc499" />

Với phương án xử lý ở tầng L7 (Nginx limit_req hoặc tương đương):
- Cách giới hạn ở layer 7 phù hợp hơn đối với xử lý crawl trên môi trường share hosting, em đã thử giới hạn IP theo website, cách này sẽ không ảnh hưởng đến các website khác của khách hàng
```
limit_req_zone $binary_remote_addr zone=thienanphu_per_ip:10m rate=15r/s;
# Giới hạn request theo IP
    limit_req zone=thienanphu_per_ip burst=10 nodelay;
    limit_req_status 429;
    limit_req_log_level warn;
```
- Với rate limit khoảng 10-15/request 1 giây, khi vượt limit sẽ trả 429 giảm tải CPU đáng kể cho server.
  <img width="900" height="400" alt="image" src="https://github.com/user-attachments/assets/b07dd2e2-f33d-434a-9f07-3dd59eb96085" />
<img width="900" height="400" alt="image" src="https://github.com/user-attachments/assets/7c1bc88e-8946-43cf-b5b0-d702e888597d" />
- Với việc rate limit ở L7, có thể dùng fail2ban để theo dõi log chứa limit request và cấu hình kết hợp nftables ở L4 nhận request từ fail2ban để chặn IP trong thời gian mình quy định

<img width="600" height="350" alt="image" src="https://github.com/user-attachments/assets/4b14202c-b299-4939-b3a9-b76e5e57f612" />

- Mô hình đề xuất:
  Chưa hoàn tất
