# Hướng dẫn sử dụng pve-advisor.sh

Tool dùng **Bash + jq**, đọc snapshot JSON để tính tải và đề xuất migrate VM.

## 1. Cài đặt

```bash
git clone https://github.com/TrungTran0/RD_test_Vietnix.git
cd RD_test_Vietnix/phan2-tool
chmod +x pve-advisor.sh
```

Yêu cầu Ubuntu Server 24.04 với Bash và các tiện ích chuẩn sẵn có. Giữ jq và hệ điều hành được cập nhật bản vá. Khi chép sang máy khác, đặt script và file JSON vào thư mục bạn muốn rồi chạy tại đó.

## 2. Xem bảng tải và đề xuất migrate

Với snapshot mới của cluster, thay `/path/cluster.json` bằng đường dẫn file thật:

```bash
./pve-advisor.sh --input /path/cluster.json --format table
```

Để thấy ngay một kế hoạch hợp lệ với **dữ liệu mẫu** đi kèm:

```bash
./pve-advisor.sh --input valid-overloaded.json --max-age 0
```

Kết quả trích từ lần chạy thực tế trên VPS:

```text
Plan: complete | Sequential replay passed all online node resource thresholds.

STEP  VMID       VM                       FROM             TO               RAM reserve GiB
1     2008       db-ent-415               hcm-c3-n01       hcm-c3-n02       68
2     2018       cloud-std-173            hcm-c3-n01       hcm-c3-n05       23
```

Nghĩa là đề xuất chuyển **VM 2008 từ node n01 sang node n02 và VM 2018 từ n01 qua n05**. Phần `Projected after` ngay bên dưới cho thấy cả các node đều `OK` sau migrate.
File valid-overloaded.jso này là dữ liệu đã sửa lại từ file snap ban đầu của đề cho sau khi:
```
Tạm bỏ n06 sai RAM cùng 12 VM thuộc node đó.
VMID 2001 trùng: giữ bản ở n01, bỏ bản ở n02.
Đổi CPU của VM 2067, 2073, 2065 về khoảng [0,1].
Bỏ VM 2390 thuộc node không tồn tại và VM 2199 RAM null.
```


| `Plan` | Cách hiểu |
|---|---|
| `complete` | Có kế hoạch đầy đủ, đã kiểm tra lại tài nguyên sau từng bước nhận và sau toàn bộ kế hoạch |
| `no_action` | Các node online đã dưới ngưỡng, không cần chuyển |
| `blocked` | Dữ liệu lỗi/thiếu/quá cũ; đọc WARNING và kiểm tra lại snapshot |
| `no_safe_plan` | Không tìm được kế hoạch đầy đủ trong giới hạn tìm kiếm; không xuất các bước chuyển dở dang |

File gốc đề cho hiện có dữ liệu bất thường nên kết quả là `blocked`:

```bash
./pve-advisor.sh --input cluster-pve-hcm-c3.original.json --max-age 0
```

`--max-age 0` dùng cho file lịch sử/mẫu. Vận hành với snapshot đang cập nhật nên bỏ tùy chọn này để giữ kiểm tra độ mới mặc định 300 giây.

## 3. Xuất JSON để pipe sang script khác

```bash
# JSON dễ đọc
./pve-advisor.sh --input cluster-pve-hcm-c3.original.json --format json --pretty

# Trích danh sách đề xuất migrate
./pve-advisor.sh --input cluster-pve-hcm-c3.original.json --format json 2> warnings.log | jq '.plan.migrations'

# Lưu report JSON và cảnh báo riêng
./pve-advisor.sh --input cluster-pve-hcm-c3.original.json --format json > report.json 2> warnings.log
```

JSON chuẩn đi ra **stdout**, cảnh báo đi ra **stderr**. Các trường cần đọc: `nodes`, `warnings`, `plan.status`, `plan.migrations`, `plan.after`. Mỗi bước chuyển có `step`, `vmid`, `source`, `target`.

Automation cần kiểm tra `data_valid`, `plan.resource_safe`, `plan.status` và `valid_until_epoch` còn hạn trước khi dùng kết quả. Report đầy đủ từ VPS có trong `valid-report.json`.

## 4. Ngưỡng và cách bảo đảm kế hoạch tài nguyên

| Thiết lập mặc định | Giá trị |
|---|---|
| Ngưỡng CPU / RAM | 80%; đạt hoặc vượt ngưỡng là quá tải |
| Ngưỡng overcommit | 4 vCPU đang chạy / core vật lý |
| Dự phòng mỗi host | 2 CPU core + 4 GiB RAM |
| Dự phòng lúc nhận migrate | Thêm 1 CPU core + 1 GiB RAM ở node đích |
| Độ mới snapshot | Tối đa 300 giây |

- CPU usage = tổng `vcpus × cpu_usage`; RAM usage = tổng `mem_used` của VM đang chạy.

- Mỗi đích phải **nhỏ hơn cả ba ngưỡng** sau khi cộng VM nhậne.

- Đổi ngưỡng để test nếu cần:

```bash
./pve-advisor.sh --input /path/cluster.json --cpu-limit 0.75 --memory-limit 0.75 --vcpu-limit 3
```

Ví dụ test:
```
root@linux-main:/var/tmp/pve-advisor-bash-20261030# ./pve-advisor.sh --input valid-overloaded.json --cpu-limit 0.75 --memory-limit 0.75 --vcpu-limit 3 --max-age 0

Kết quả:
Cluster: pve-hcm-c3 | collected: 2026-10-27T09:00:00+07:00
CPU/RAM = running VM sums. PARTIAL values are provisional.
Limits: CPU 75%, RAM 75%, vCPU 3x; host reserve 2 cores + 4 GiB.
NODE                CPU cores/%            RAM GiB/%    vCPU/core STATE        DATA     REASONS
hcm-c3-n01          54.99/85.9%           476.16/93%        1.72x OVERLOADED   complete cpu,memory
hcm-c3-n02          25.01/39.1%            281.6/55%        1.25x OK           complete -
hcm-c3-n03            18.24/38%           180.48/47%        1.67x OK           complete -
hcm-c3-n04                 0/0%                 0/0%           0x OFFLINE      complete -
hcm-c3-n05            44.78/70%         367.94/71.9%        0.94x OK           complete -
Plan: complete | Sequential replay passed all online node resource thresholds.

STEP  VMID       VM                       FROM             TO               RAM reserve GiB
1     2008       db-ent-415               hcm-c3-n01       hcm-c3-n02       68
2     2027       s3-gw-616                hcm-c3-n01       hcm-c3-n03       60

Projected after (incoming RAM reserved at mem_max):
NODE                CPU cores/%            RAM GiB/%    vCPU/core STATE        DATA     REASONS
hcm-c3-n01          45.97/71.8%         375.77/73.4%        1.56x OK           complete -
hcm-c3-n02          32.07/50.1%         339.34/66.3%        1.38x OK           complete -
hcm-c3-n03           20.2/42.1%         223.13/58.1%        1.71x OK           complete -
hcm-c3-n04                 0/0%                 0/0%           0x OFFLINE      complete -
hcm-c3-n05            44.78/70%         367.94/71.9%        0.94x OK           complete -
Refresh snapshot and complete PVE preflight before each sequential migration.
```
## 5. Chạy unit test

Test nằm sẵn trong file `.sh`, không cần file test hay framework riêng:

```bash
./pve-advisor.sh test
```

16 test kiểm tra tính tải/ngưỡng, dữ liệu sai/thiếu, kế hoạch migrate và sức chứa đích, node offline/VM khóa, nhiều bước chuyển, hai output và watch phục hồi sau lỗi. Xem `self-test.log`. Chạy riêng một trường hợp:

```bash
./pve-advisor.sh test --case complete_plan
./pve-advisor.sh test --case missing_field
```

## 6. Kiểm tra xử lý JSON lỗi hoặc thiếu trường

Chạy thử với file JSON hỏng:

```bash
printf '{"nodes": [' > test-invalid.json
./pve-advisor.sh --input test-invalid.json --format json
```

Tool trả report `blocked`, WARNING mã `input_error` và vị trí lỗi parser. Thử thiếu trường VM bằng file mẫu:

```bash
jq 'del(.vms[0].vcpus)' valid-overloaded.json > test-missing-field.json
./pve-advisor.sh --input test-missing-field.json --max-age 0
```

Cảnh báo nhận diện rõ bản ghi:

```text
WARNING [invalid_vcpus] vms[0] vmid=101 node=a: vcpus must be a positive integer <=1000000
```

Input lỗi làm tool trả **exit code 2 có chủ đích**, không traceback/crash và không xuất migrate. Nếu cả file không parse được thì chỉ rõ root/line/column; nếu bản ghi parse được thì nêu index và VMID/node nhận diện được. Xem exit code ngay sau lệnh bằng `echo $?`.

Exit code: **0** = complete/no_action; **2** = input/config lỗi hoặc quá cũ; **3** = chưa có kế hoạch an toàn.

Chạy định kỳ với file đang được collector cập nhật:

```bash
./pve-advisor.sh watch --input /path/cluster.json --interval 60 --format json
```

Watch xuất một JSON report mỗi dòng, tiếp tục chạy khi file lỗi và tự phục hồi khi file hợp lệ trở lại; Ctrl+C để dừng. Collector nên thay file atomically. Tham số khác: `./pve-advisor.sh --help`.
