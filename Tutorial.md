# Báo cáo so sánh docker và podman

# Docker vs Podman

> Mục tiêu: So sánh **khách quan, thực tế, tái lập được** giữa Docker và Podman trên Linux. Tài liệu này gồm: kịch bản benchmark, command cụ thể, script automation, và recommendation theo use case.
> 

---

## 1. Tổng quan kiến trúc — Hiểu trước khi đo

| Khía cạnh | Docker | Podman |
| --- | --- | --- |
| Architecture | Client-server (daemon `dockerd`) | Daemonless (fork/exec) |
| Rootless | Hỗ trợ (cấu hình thêm) | Native, mặc định |
| Image format | OCI | OCI (tương thích) |
| Build engine | BuildKit | Buildah |
| Compose | `docker compose` (Go plugin) | `podman-compose` / Quadlet / `podman kube play` |
| Networking | bridge (libnetwork) / CNI | netavark (mặc định mới) / CNI |
| Pod abstraction | Không có | Có (giống K8s pod) |
| Systemd integration | Qua `docker.service` | Native (`podman generate systemd`, Quadlet) |

**Hệ quả với benchmark:**
- Podman không có daemon → **idle memory** thấp hơn, **first-call latency** có thể khác.
- Rootless dùng `slirp4netns`/`pasta` cho network → **network throughput thấp hơn** so với bridge rootful.
- Cùng overlay2 storage → **disk I/O tương đương**.
- BuildKit (Docker) thường nhanh hơn Buildah ở cache layer phức tạp; Buildah linh hoạt hơn ở scripted builds.

---

## 2. Môi trường test chuẩn (Baseline) — Cực kỳ quan trọng

### 2.1. Hardware & OS

- **VM hoặc bare-metal Linux** (Ubuntu 24.04 LTS / Fedora 40 khuyến nghị).
- Tối thiểu: 4 vCPU, 8 GB RAM, 40 GB SSD.
- **Cùng một máy, chạy lần lượt** — không so sánh giữa hai máy khác nhau.

### 2.2. Cấu hình hệ thống để giảm noise

```bash
# Tắt swap (tránh ảnh hưởng đo memory)
sudo swapoff -a

# Cố định CPU governor ở performance
sudo cpupower frequency-set -g performance

# Tắt các service không cần thiết
sudo systemctl stop snapd cron unattended-upgrades 2>/dev/null

# Drop caches trước mỗi lần đo cold start
sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'

# Kiểm tra không có process nặng
top -bn1 | head -20
```

### 2.3. Cài đặt phiên bản chính thức

```bash
# Docker (Ubuntu)
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER

# Podman (Ubuntu 24.04 đã có sẵn package mới)
sudo apt install -y podman buildah skopeo

# Kiểm tra version (ghi lại để báo cáo)
docker --version && docker info | grep -E 'Server Version|Storage Driver|Cgroup'
podman --version && podman info | grep -E 'version|graphDriverName|cgroupVersion'
```

### 2.4. Nguyên tắc fairness (BẮT BUỘC)

| Nguyên tắc | Lý do |
| --- | --- |
| Cùng base image (digest, không phải tag) | Tag `latest` có thể khác nhau giữa các lần pull |
| Cùng resource limits (`--cpus`, `--memory`) | Tránh một bên bị throttle |
| Cùng storage driver (overlay2) | Loại bỏ biến số filesystem |
| Chạy ≥ 10 lần, lấy median + p95 | Loại trừ outlier |
| Warmup trước (1-2 lần “throw-away”) | Giảm cold-cache bias |
| So sánh **rootful vs rootful** và **rootless vs rootless** riêng | Không trộn vì khác kernel path |
| Tắt telemetry/auto-update | Tránh background work |
| Cùng kernel, cùng distro, cùng filesystem | Loại bỏ biến số môi trường |

---

## 3. Các kịch bản benchmark

### Kịch bản 1: Container Start/Stop Latency

**Mục tiêu:** Đo overhead của container runtime khi khởi tạo và dừng container.

**Tool:** `hyperfine` (đo wall-clock, có warmup, statistics)

**Setup:**

```bash
# Pull image trước (loại trừ network khỏi phép đo)
DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' alpine:3.20 2>/dev/null \
  || docker pull alpine:3.20 && docker inspect --format='{{index .RepoDigests 0}}' alpine:3.20)
podman pull alpine:3.20
```

**Command:**

```bash
# Cold start: tạo + chạy + thoát
hyperfine --warmup 3 --runs 20 \
  --prepare 'docker rm -f bench 2>/dev/null; sync' \
  'docker run --rm --name bench alpine:3.20 true' \
  --prepare 'podman rm -f bench 2>/dev/null; sync' \
  'podman run --rm --name bench alpine:3.20 true'

# Warm start: container đã exist, chỉ start lại
docker create --name dbench alpine:3.20 sleep 1
podman create --name pbench alpine:3.20 sleep 1
hyperfine --warmup 3 --runs 20 \
  'docker start -a dbench' \
  'podman start -a pbench'
```

**Metrics:**
- Mean, median, min, max startup time (ms)
- Standard deviation
- p95 / p99

**Fairness:** Cùng image digest, cùng command (`true`/`sleep`), cùng `--rm` flag.

---

### Kịch bản 2: Idle Memory & CPU Footprint

**Mục tiêu:** So sánh memory daemon Docker dùng vs Podman không daemon.

**Tool:** `ps`, `smem`, `pidstat`

**Command:**

```bash
# Docker daemon footprint
ps -o pid,rss,vsz,cmd -p $(pgrep -f dockerd) | tail -1
smem -P dockerd -k

# Podman: không daemon, chỉ đo khi có container running
# Khởi 1 container nginx và đo runtime overhead
docker run -d --name dweb nginx:1.27-alpine
podman run -d --name pweb nginx:1.27-alpine

sleep 5  # ổn định
pidstat -r -p $(pgrep dockerd) 1 5
pidstat -r -p $(pgrep -f 'conmon.*pweb') 1 5

# Đo tổng memory (bao gồm container + runtime + daemon)
docker stats --no-stream dweb
podman stats --no-stream pweb
```

**Metrics:**
- RSS daemon (Docker only)
- RSS conmon (Podman)
- Container memory usage
- CPU usage idle (%)

**Fairness:** Cùng image, cùng số container, đo sau khi đã ổn định ≥ 5 giây.

---

### Kịch bản 3: Networking Performance

**Mục tiêu:** Đo throughput network qua bridge (rootful) và slirp4netns/pasta (rootless).

**Tool:** `iperf3`

**Setup:**

```bash
# Server container
docker run -d --name iperf-srv -p 5201:5201 networkstatic/iperf3 -s
podman run -d --name iperf-srv -p 5202:5201 networkstatic/iperf3 -s
```

**Command:**

```bash
# Container -> Host (Docker rootful)
docker run --rm networkstatic/iperf3 -c <host-ip> -p 5201 -t 30 -P 4

# Container -> Host (Podman rootless)
podman run --rm networkstatic/iperf3 -c <host-ip> -p 5202 -t 30 -P 4

# Container -> Container same network
docker network create benchnet
docker run -d --name srv --network benchnet networkstatic/iperf3 -s
docker run --rm --network benchnet networkstatic/iperf3 -c srv -t 30 -P 4

# Tương tự cho podman
podman network create benchnet
podman run -d --name srv --network benchnet networkstatic/iperf3 -s
podman run --rm --network benchnet networkstatic/iperf3 -c srv -t 30 -P 4

# Test rootless với pasta (Podman 4.7+) — thường nhanh hơn slirp4netns
podman run --rm --network=pasta networkstatic/iperf3 -c <host-ip> -t 30
```

**Metrics:**
- Throughput (Gbits/sec)
- Retransmits
- Latency (dùng `--time` mode hoặc `qperf`)

**Fairness:** Cùng `-t 30 -P 4`, cùng host network điều kiện, chạy lần lượt không song song.

**Lưu ý quan trọng:** Rootless network bị giới hạn bởi userspace network stack — đây là **trade-off** đã biết, không phải bug.

---

### Kịch bản 4: Disk I/O Performance

**Mục tiêu:** Đo I/O qua overlay2 và qua volume mount.

**Tool:** `fio`

**Command:**

```bash
# Tạo fio job file
cat > /tmp/fio-bench.fio <<'EOF'
[global]
ioengine=libaio
direct=1
runtime=30
time_based
group_reporting
size=1G

[seq-read]
rw=read
bs=1M

[seq-write]
rw=write
bs=1M

[rand-read]
rw=randread
bs=4k
iodepth=32

[rand-write]
rw=randwrite
bs=4k
iodepth=32
EOF

# Test trên overlay2 layer (không volume)
docker run --rm -v /tmp/fio-bench.fio:/job.fio:ro \
  -v /tmp/fio-out-docker:/out \
  alpine:3.20 sh -c 'apk add --no-cache fio >/dev/null && cd /out && fio /job.fio'

podman run --rm -v /tmp/fio-bench.fio:/job.fio:ro \
  -v /tmp/fio-out-podman:/out \
  alpine:3.20 sh -c 'apk add --no-cache fio >/dev/null && cd /out && fio /job.fio'

# Test với named volume
docker volume create dvol
docker run --rm -v dvol:/data -v /tmp/fio-bench.fio:/job.fio \
  alpine:3.20 sh -c 'apk add --no-cache fio >/dev/null && cd /data && fio /job.fio'

podman volume create pvol
podman run --rm -v pvol:/data -v /tmp/fio-bench.fio:/job.fio \
  alpine:3.20 sh -c 'apk add --no-cache fio >/dev/null && cd /data && fio /job.fio'
```

**Metrics:**
- Sequential read/write bandwidth (MB/s)
- Random read/write IOPS
- Latency p50, p99

**Fairness:** Cùng filesystem host (ext4/xfs), cùng image, cùng fio config.

---

### Kịch bản 5: Scale — Khởi tạo nhiều container đồng thời

**Mục tiêu:** Đo khả năng scale ra nhiều container.

**Tool:** Bash + `time` + `xargs -P`

**Command:**

```bash
# Khởi 100 container song song
N=100

# Docker
time (seq 1 $N | xargs -P 20 -I{} docker run -d --name dbench-{} alpine:3.20 sleep 60)
docker ps -q --filter "name=dbench" | wc -l
time (docker ps -q --filter "name=dbench" | xargs -P 20 docker rm -f)

# Podman
time (seq 1 $N | xargs -P 20 -I{} podman run -d --name pbench-{} alpine:3.20 sleep 60)
podman ps -q --filter "name=pbench" | wc -l
time (podman ps -q --filter "name=pbench" | xargs -P 20 podman rm -f)
```

**Metrics:**
- Total time để khởi N container
- Memory tổng tiêu thụ
- Số container thành công / thất bại
- Time to first failure (nếu có)

**Fairness:** Cùng `-P` (parallelism), cùng N, cùng image.

**Lưu ý:** Podman fork mỗi container → có thể chạm `pids_max` cgroup nhanh hơn nếu hệ thống cấu hình thấp. Docker có daemon centralized → throttling tập trung.

---

### Kịch bản 6: Rootless vs Rootful

**Mục tiêu:** Đo overhead của rootless mode (do user namespace + slirp4netns/fuse-overlayfs).

**Setup:**

```bash
# Docker rootless: cần cài rootless-extras
dockerd-rootless-setuptool.sh install
# Sau đó dùng socket: export DOCKER_HOST=unix:///run/user/$UID/docker.sock

# Podman: rootless là default khi chạy non-root user
```

**Command:** Lặp lại Kịch bản 1, 3, 4 ở cả 2 mode.

**Metrics so sánh:**

| Metric | Rootful | Rootless | Penalty |
| --- | --- | --- | --- |
| Startup latency | baseline | +X% | thường < 10% |
| Network throughput | baseline | -Y% | thường 30-60% (slirp4netns), 10-30% (pasta) |
| Disk I/O (overlay2) | baseline | -Z% | thường 5-15% (fuse-overlayfs); ~0% nếu native overlay rootless (kernel ≥ 5.13) |

**Fairness:** Đảm bảo cùng kernel version (≥ 5.13 cho native rootless overlay).

---

### Kịch bản 7: Image Build Performance

**Mục tiêu:** So sánh BuildKit (Docker) vs Buildah (Podman).

**Setup Dockerfile:**

```docker
# Dockerfile.bench
FROM node:20-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci

FROM node:20-alpine AS build
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN npm run build

FROM nginx:1.27-alpine
COPY --from=build /app/dist /usr/share/nginx/html
```

**Command:**

```bash
# Cold build (no cache)
hyperfine --warmup 1 --runs 5 \
  --prepare 'docker builder prune -af' \
  'docker build --no-cache -f Dockerfile.bench -t bench:docker .' \
  --prepare 'podman system prune -af' \
  'podman build --no-cache -f Dockerfile.bench -t bench:podman .'

# Warm build (with cache, đổi 1 file source)
hyperfine --warmup 2 --runs 10 \
  --prepare 'echo "// $(date +%N)" >> src/main.js' \
  'docker build -f Dockerfile.bench -t bench:docker .' \
  'podman build -f Dockerfile.bench -t bench:podman .'

# BuildKit features test (Docker)
DOCKER_BUILDKIT=1 docker build --cache-to type=local,dest=/tmp/cache \
  --cache-from type=local,src=/tmp/cache -t bench:bk .

# Buildah equivalent
buildah bud --layers --cache-from localhost/bench-cache -t bench:bah .
```

**Metrics:**
- Total build time (cold/warm)
- Cache hit ratio
- Final image size
- Layers count

**Fairness:** Cùng Dockerfile, cùng base image, prune cache trước cold build.

---

### Kịch bản 8: Real Workload — Web Server (HTTP)

**Mục tiêu:** Đo hiệu năng HTTP serving thực tế.

**Tool:** `wrk` hoặc `oha` (Rust, hiện đại hơn)

**Setup:**

```bash
docker run -d --name dweb -p 8081:80 nginx:1.27-alpine
podman run -d --name pweb -p 8082:80 nginx:1.27-alpine

# Tạo file test 10KB
docker exec dweb sh -c 'dd if=/dev/urandom of=/usr/share/nginx/html/test.bin bs=1K count=10'
podman exec pweb sh -c 'dd if=/dev/urandom of=/usr/share/nginx/html/test.bin bs=1K count=10'
```

**Command:**

```bash
# wrk: 30s, 4 threads, 100 connections
wrk -t4 -c100 -d30s --latency http://localhost:8081/test.bin
wrk -t4 -c100 -d30s --latency http://localhost:8082/test.bin

# oha alternative (đẹp hơn cho demo)
oha -z 30s -c 100 http://localhost:8081/test.bin
oha -z 30s -c 100 http://localhost:8082/test.bin
```

**Metrics:**
- Requests/sec
- Latency p50, p95, p99
- Transfer/sec
- Errors

---

### Kịch bản 9: Real Workload — Database (PostgreSQL)

**Tool:** `pgbench`

**Setup:**

```bash
docker run -d --name dpg -e POSTGRES_PASSWORD=bench -p 5433:5432 postgres:16
podman run -d --name ppg -e POSTGRES_PASSWORD=bench -p 5434:5432 postgres:16
sleep 10  # đợi init

# Init pgbench data (scale 50 = ~750MB)
PGPASSWORD=bench pgbench -h localhost -p 5433 -U postgres -i -s 50 postgres
PGPASSWORD=bench pgbench -h localhost -p 5434 -U postgres -i -s 50 postgres
```

**Command:**

```bash
# TPC-B-like workload
PGPASSWORD=bench pgbench -h localhost -p 5433 -U postgres -c 16 -j 4 -T 60 -P 5 postgres
PGPASSWORD=bench pgbench -h localhost -p 5434 -U postgres -c 16 -j 4 -T 60 -P 5 postgres
```

**Metrics:**
- TPS (transactions per second) including/excluding connections
- Latency average
- Latency stddev

---

### Kịch bản 10: Batch Processing (CPU-bound)

**Tool:** `sysbench`

```bash
# CPU prime calculation
docker run --rm --cpus=2 alpine:3.20 sh -c \
  'apk add --no-cache sysbench >/dev/null && sysbench cpu --cpu-max-prime=20000 --threads=2 --time=30 run'

podman run --rm --cpus=2 alpine:3.20 sh -c \
  'apk add --no-cache sysbench >/dev/null && sysbench cpu --cpu-max-prime=20000 --threads=2 --time=30 run'
```

**Metrics:** Events/sec, latency p95.

**Mục đích:** Verify rằng CPU-bound workload **không** có khác biệt đáng kể (cả hai dùng cùng kernel runc/crun) — nếu khác biệt > 2-3%, có vấn đề về cấu hình.

---

## 4. Bảng so sánh kết quả mẫu (placeholder, điền sau khi đo)

| Benchmark | Metric | Docker | Podman | Δ (%) | Winner |
| --- | --- | --- | --- | --- | --- |
| Cold start (rootful) | mean ms | 420 | 380 | -9.5% | Podman |
| Warm start | mean ms | 180 | 165 | -8.3% | Podman |
| Idle daemon RAM | MB | 95 | 0 | -100% | Podman |
| Container RAM (nginx) | MB | 8.2 | 8.4 | +2.4% | ≈ tie |
| iperf3 host↔︎container (rootful) | Gbps | 28.5 | 28.1 | -1.4% | ≈ tie |
| iperf3 rootless | Gbps | 4.2 | 4.5 (pasta) | +7% | Podman |
| fio randread IOPS (overlay) | k IOPS | 85 | 84 | -1.2% | ≈ tie |
| fio randread IOPS (volume) | k IOPS | 142 | 141 | -0.7% | ≈ tie |
| Scale 100 containers | s | 18.4 | 16.9 | -8.2% | Podman |
| Cold build (Node app) | s | 92 | 108 | +17% | Docker |
| Warm build (1 file change) | s | 8.1 | 11.4 | +41% | Docker |
| nginx wrk req/s | req/s | 78,500 | 77,900 | -0.8% | ≈ tie |
| pgbench TPS (16c, scale 50) | TPS | 4,820 | 4,790 | -0.6% | ≈ tie |
| sysbench CPU events/s | ev/s | 1,540 | 1,538 | -0.1% | tie |

> Lưu ý: Số liệu trên là **ví dụ minh họa** dựa trên xu hướng phổ biến quan sát được — bạn phải chạy thực tế trên máy của mình.
> 

---

## 5. Demo Flow 10–15 phút

| Phút | Nội dung | Action |
| --- | --- | --- |
| 0:00–1:00 | **Intro & motivation** | Vì sao so sánh? Khác biệt kiến trúc (1 slide) |
| 1:00–2:00 | **Setup môi trường** | Show `docker --version`, `podman --version`, `uname -a`, `free -h` |
| 2:00–3:30 | **Kịch bản 1: Startup latency** | Chạy hyperfine live → show kết quả ngay |
| 3:30–5:00 | **Kịch bản 2: Memory footprint** | `ps aux \| grep dockerd`, `podman info`, biểu đồ |
| 5:00–6:30 | **Kịch bản 3: Network** | iperf3 rootful + rootless side-by-side |
| 6:30–8:00 | **Kịch bản 5: Scale 100 containers** | Chạy đồng thời 2 terminal, đo bằng `time` |
| 8:00–9:30 | **Kịch bản 7: Build performance** | Demo cold + warm build, show BuildKit advantage |
| 9:30–11:30 | **Kịch bản 8: Real workload (nginx + wrk)** | Live load test, show latency histogram |
| 11:30–13:00 | **Tổng hợp & biểu đồ** | Hiển thị bảng kết quả, các chart đã chuẩn bị |
| 13:00–14:30 | **Recommendations** | Khi nào chọn Docker, khi nào chọn Podman |
| 14:30–15:00 | **Q&A** |  |

**Tip trình bày:**
- Pre-pull image trước demo để tránh chờ network.
- Mở 2 terminal cạnh nhau (tmux split): trái Docker, phải Podman.
- Có sẵn screenshot/biểu đồ phòng khi live demo lỗi.
- Chuẩn bị câu trả lời cho câu hỏi: *“Docker đã có rootless rồi, sao còn dùng Podman?”*

---

## 6. Checklist thực hiện (in ra, tick từng mục)

### Trước demo (T-1 ngày)

- [ ]  VM/máy sạch, chỉ cài Docker + Podman + tools
- [ ]  Ghi version: kernel, docker, podman, runc, crun, conmon
- [ ]  Tắt swap, set CPU governor performance
- [ ]  Pull tất cả image cần dùng (alpine, nginx, postgres, node, networkstatic/iperf3)
- [ ]  Cài tools: `hyperfine`, `iperf3`, `fio`, `wrk`/`oha`, `sysbench`, `pidstat`, `smem`, `pgbench`
- [ ]  Test chạy thử **toàn bộ** script automation 1 lần
- [ ]  Backup kết quả (CSV) phòng khi demo lỗi

### Ngay trước demo (T-30 phút)

- [ ]  Reboot máy (state sạch)
- [ ]  Drop caches: `sync && echo 3 > /proc/sys/vm/drop_caches`
- [ ]  Tắt browser, IDE, các app nặng
- [ ]  Mở terminal phóng to, font ≥ 16px
- [ ]  Mở sẵn slide tổng kết + bảng kết quả

### Trong demo

- [ ]  Nói rõ phiên bản, hardware đầu demo
- [ ]  Chạy mỗi benchmark **ít nhất 3 lần** trên live
- [ ]  Ghi lại số liệu thực vào bảng (đừng đọc số “tủ”)
- [ ]  Highlight cả điểm **mạnh và yếu** của cả hai

### Sau demo

- [ ]  Export CSV kết quả
- [ ]  Push code + raw data lên repo
- [ ]  Viết blog/report ghi rõ điều kiện test

---

## 7. Biểu đồ trực quan hóa khuyến nghị

| Loại biểu đồ | Dùng cho | Tool |
| --- | --- | --- |
| **Bar chart (grouped)** | Startup time, build time, TPS | matplotlib / Excel |
| **Box plot** | Phân bố latency (variance, outlier) | matplotlib `boxplot` |
| **Line chart** | Scale test: containers vs time | matplotlib |
| **Stacked bar** | Memory breakdown (daemon + container) | matplotlib |
| **Radar chart** | Tổng quan đa chiều (cho slide kết) | plotly |
| **Latency histogram** | wrk/oha output (p50/p95/p99) | `wrk2` `--latency` |
| **Heatmap** | Scale × Time × Memory | seaborn |

**Quy tắc visualize công bằng:**
- Trục Y luôn bắt đầu từ 0 (trừ box plot).
- Hiển thị error bar (stddev hoặc IQR).
- Cùng màu Docker / Podman xuyên suốt slide.
- Annotate số cụ thể, đừng để người xem đoán.

---

## 8. Script automation tự động (Bash)

Lưu thành `bench.sh`, chạy `chmod +x bench.sh && ./bench.sh`. Script chạy hết các kịch bản chính và xuất CSV.

```bash
#!/usr/bin/env bash
# bench.sh — Docker vs Podman automated benchmark
set -euo pipefail

OUTDIR="${OUTDIR:-./bench-results-$(date +%Y%m%d-%H%M%S)}"
RUNS="${RUNS:-10}"
WARMUP="${WARMUP:-3}"
SCALE_N="${SCALE_N:-50}"
IMAGE_ALPINE="alpine:3.20"
IMAGE_NGINX="nginx:1.27-alpine"

mkdir -p "$OUTDIR"
CSV="$OUTDIR/results.csv"
echo "benchmark,metric,docker,podman,unit" > "$CSV"

log() { echo -e "\033[1;34m[bench]\033[0m$*" | tee -a "$OUTDIR/run.log"; }
need() { command -v "$1" >/dev/null || { echo "Missing:$1"; exit 1; }; }

for t in docker podman hyperfine jq; do need "$t"; done

# === Pre-flight ===
log "Pulling images..."
docker pull "$IMAGE_ALPINE" >/dev/null
docker pull "$IMAGE_NGINX" >/dev/null
podman pull "$IMAGE_ALPINE" >/dev/null
podman pull "$IMAGE_NGINX" >/dev/null

log "Versions:"
{
  docker version --format '{{.Server.Version}}'
  podman version --format '{{.Server.Version}}'
  uname -r
} | tee "$OUTDIR/versions.txt"

# === 1. Startup latency ===
log "Benchmark 1: Cold start latency ($RUNS runs)"
hyperfine --warmup "$WARMUP" --runs "$RUNS" \
  --export-json "$OUTDIR/01-startup.json" \
  "docker run --rm$IMAGE_ALPINE true" \
  "podman run --rm$IMAGE_ALPINE true"

D=$(jq '.results[0].mean*1000' "$OUTDIR/01-startup.json")
P=$(jq '.results[1].mean*1000' "$OUTDIR/01-startup.json")
echo "startup_cold,mean,$D,$P,ms" >> "$CSV"

# === 2. Idle memory ===
log "Benchmark 2: Idle memory"
docker run -d --name bench-mem-d "$IMAGE_NGINX" >/dev/null
podman run -d --name bench-mem-p "$IMAGE_NGINX" >/dev/null
sleep 5
DOCKER_DAEMON_RSS=$(ps -o rss= -p $(pgrep -x dockerd | head -1) 2>/dev/null || echo 0)
PODMAN_CONMON_RSS=$(ps -o rss= -C conmon 2>/dev/null | awk '{s+=$1} END {print s+0}')
echo "memory_idle,daemon_rss,$DOCKER_DAEMON_RSS,$PODMAN_CONMON_RSS,KB" >> "$CSV"
docker rm -f bench-mem-d >/dev/null
podman rm -f bench-mem-p >/dev/null

# === 3. Scale test ===
log "Benchmark 3: Scale ($SCALE_N containers)"
for engine in docker podman; do
  $engine ps -aq | xargs -r $engine rm -f >/dev/null 2>&1 || true
  start=$(date +%s.%N)
  seq 1 "$SCALE_N" | xargs -P 20 -I{} $engine run -d --name b{}-$engine "$IMAGE_ALPINE" sleep 60 >/dev/null
  end=$(date +%s.%N)
  eval "${engine^^}_SCALE=$(echo "$end -$start" | bc)"
  $engine ps -aq --filter "name=b" | xargs $engine rm -f >/dev/null
done
echo "scale_${SCALE_N}_containers,total_time,$DOCKER_SCALE,$PODMAN_SCALE,s" >> "$CSV"

# === 4. HTTP throughput ===
if command -v wrk >/dev/null; then
  log "Benchmark 4: HTTP (nginx + wrk)"
  docker run -d --name bench-http-d -p 18081:80 "$IMAGE_NGINX" >/dev/null
  podman run -d --name bench-http-p -p 18082:80 "$IMAGE_NGINX" >/dev/null
  sleep 3
  D_RPS=$(wrk -t4 -c100 -d20s http://localhost:18081/ 2>&1 | awk '/Requests\/sec/{print $2}')
  P_RPS=$(wrk -t4 -c100 -d20s http://localhost:18082/ 2>&1 | awk '/Requests\/sec/{print $2}')
  echo "http_throughput,req_per_sec,$D_RPS,$P_RPS,req/s" >> "$CSV"
  docker rm -f bench-http-d >/dev/null
  podman rm -f bench-http-p >/dev/null
fi

# === 5. CPU sysbench ===
log "Benchmark 5: CPU (sysbench)"
SYSBENCH_CMD='apk add --no-cache sysbench >/dev/null 2>&1 && sysbench cpu --cpu-max-prime=20000 --threads=2 --time=20 run | awk "/events per second/{print \$4}"'
D_CPU=$(docker run --rm --cpus=2 "$IMAGE_ALPINE" sh -c "$SYSBENCH_CMD")
P_CPU=$(podman run --rm --cpus=2 "$IMAGE_ALPINE" sh -c "$SYSBENCH_CMD")
echo "cpu_sysbench,events_per_sec,$D_CPU,$P_CPU,ev/s" >> "$CSV"

# === Summary ===
log "Done. Results in$CSV"
column -t -s, "$CSV"
```

**Để chạy đầy đủ hơn**, mở rộng script với fio, pgbench, build benchmark theo template trên.

---

## 9. Khi nào Podman tốt hơn? Khi nào Docker tốt hơn?

### Podman thường tốt hơn khi:

- **Bảo mật quan trọng**: rootless là default, không có daemon chạy root → giảm attack surface.
- **Multi-tenant / shared host**: mỗi user chạy podman riêng, không có daemon dùng chung.
- **Edge / IoT / CI runner**: không cần daemon → tiết kiệm RAM khi idle, restart đơn giản.
- **Systemd-native deployment**: `quadlet`, `podman generate systemd` rất “Linux idiomatic”.
- **Kubernetes-style local dev**: `podman pod`, `podman kube play` chạy trực tiếp K8s YAML.
- **Air-gapped / restricted env**: không cần daemon → audit và lockdown đơn giản hơn.
- **Startup latency nhạy cảm**: không có round-trip qua daemon socket.

### Docker thường tốt hơn khi:

- **Build phức tạp**: BuildKit có cache backend (S3, GHA, registry), parallel stages mạnh hơn Buildah trong nhiều case.
- **Hệ sinh thái tooling**: Docker Desktop, Docker Hub workflows, Compose v2, extensions.
- **Tích hợp CI/CD trưởng thành**: hầu hết tài liệu, action GitHub, GitLab runner mặc định Docker.
- **Đội ngũ đã quen**: chi phí training thấp, ít “gotcha” về user namespace.
- **Networking phức tạp** (overlay, swarm): Docker Swarm đã trưởng thành (dù đang ít phát triển).
- **Windows containers**: Podman trên Windows vẫn qua VM, Docker Desktop tích hợp tốt hơn.
- **Macros / subuid edge cases**: rootless Podman cần cấu hình `subuid`/`subgid` đúng — Docker rootful né được vấn đề này.

### Khi gần như không khác biệt:

- CPU-bound workloads (cùng kernel runtime).
- Disk I/O qua named volume.
- HTTP serving (nginx, caddy, …) đơn giản.
- Container lifecycle cơ bản trong dev environment cá nhân.

---

## 10. Recommendation theo use case

| Use case | Khuyến nghị | Lý do |
| --- | --- | --- |
| Dev cá nhân trên Linux | **Podman** hoặc Docker | Tùy quen |
| Dev trên macOS/Windows | **Docker Desktop** | UX tốt hơn |
| CI/CD runner (GitHub/GitLab) | **Podman** (tiết kiệm RAM, rootless) hoặc Docker | Cả hai đều ổn |
| Production K8s nodes | **Không liên quan** — dùng containerd/CRI-O trực tiếp | Cả Docker và Podman không phải runtime cuối cùng |
| Server bare-metal chạy vài service | **Podman + Quadlet** | Native systemd, rootless, không daemon |
| Edge / IoT (Raspberry Pi, ARM SBC) | **Podman** | Idle RAM thấp, không daemon crash |
| Air-gapped / regulated env (banking, gov) | **Podman rootless** | Compliance dễ hơn |
| High-frequency container churn (CI tests) | **Podman** (startup nhanh) hoặc Docker BuildKit | Đo trên workload cụ thể |
| Build pipeline phức tạp đa stage | **Docker + BuildKit** hoặc Buildah scripted | BuildKit cache mạnh |
| Migration từ docker-compose | **Docker Compose** trước, dần chuyển Quadlet | Tránh disrupt |
| Học container theo chuẩn OCI/K8s | **Podman** | Pod abstraction giống K8s |

---

## 11. Pitfalls & Anti-patterns trong benchmarking

❌ **Không được làm:**
- So sánh Docker rootful vs Podman rootless và kết luận “Podman chậm hơn” — apples vs oranges.
- Đo 1-2 lần rồi kết luận — variance có thể > 30%.
- Dùng `time docker run ...` mà không warmup → cold cache làm sai lệch.
- So sánh trên 2 máy khác nhau (“Docker chạy trên laptop, Podman chạy trên VM”).
- Không ghi lại kernel version — kernel ≥ 5.13 thay đổi rất nhiều với rootless overlay.
- Bỏ qua `docker-init` vs `tini` khác biệt khi đo signal handling.
- Test image build mà không clear cache → kết quả phụ thuộc thứ tự chạy.
- Quên tắt BuildKit khi muốn so sánh “vanilla” build (Docker mặc định BuildKit từ 23.0).

✅ **Bắt buộc:**
- Document version chính xác của: kernel, docker, podman, runc/crun, conmon, containerd.
- Chạy ≥ 10 runs cho mỗi metric, report median + p95 + stddev.
- Public raw data (CSV/JSON) cùng với conclusion.
- State giả định và môi trường rõ ràng ngay đầu báo cáo.

---

## 12. Tài liệu tham khảo nên đọc thêm

- Red Hat: Podman vs Docker comparison (đọc với tinh thần phản biện vì có bias)
- Docker Engine release notes (xem feature mới qua từng version)
- “Container Performance Analysis” — Brendan Gregg
- IBM Research: Container performance studies
- Phoronix Test Suite có sẵn module so sánh container runtime

---

**Kết luận quan trọng nhất:** Không có “winner” tuyệt đối. **Đo trên workload thực tế của bạn**, trên hardware thật của bạn, với phiên bản hiện tại — đó là khuyến nghị duy nhất luôn đúng. Tài liệu này cho bạn framework để làm điều đó một cách công bằng.