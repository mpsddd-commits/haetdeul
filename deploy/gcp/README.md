# GCP VM 배포 — 가비아 도메인 연결

Windows PC 배포(`deploy/deploy.ps1`)를 GCP Compute Engine VM 한 대로 옮깁니다.
기존 `compose.yml` 은 그대로 두고 `deploy/gcp/compose.gcp.yml` 을 덧씌웁니다.

```text
사용자 → https://<도메인>   (가비아 DNS A 레코드 → GCP 고정 IP)
          └ VM
             caddy :80/:443  ── 자동 HTTPS (Let's Encrypt)
               └ frontend :80 (nginx 정적)
                   ├ /api/*    → backend :8000
                   └ /api/ml/* → backend → ml-backend :8102 (haetdeul-ml)
```

| 파일 | 역할 |
| --- | --- |
| `compose.gcp.yml` | caddy · ml-backend 추가, 포트 재배치 |
| `Caddyfile` | 도메인 → frontend, www → 루트 도메인 리다이렉트 |
| `deploy.sh` | pull → 교체 → 헬스체크 → 실패 시 롤백 (`deploy.ps1` 과 같은 흐름) |
| `env.example` | VM 의 `/srv/haetdeul/.env` 틀 |

---

## 1. GCP — VM 만들기

1. [console.cloud.google.com](https://console.cloud.google.com) → 프로젝트 생성 → 결제 계정 연결
2. **Compute Engine → VM 인스턴스 → 만들기**

   | 항목 | 값 |
   | --- | --- |
   | 리전 / 영역 | `asia-northeast3` (서울) / `asia-northeast3-a` |
   | 머신 | `e2-medium` (2 vCPU · 4GB). 재학습까지 돌리면 `e2-standard-2` |
   | 부팅 디스크 | Ubuntu 24.04 LTS · 30GB 이상 |
   | 방화벽 | **HTTP 트래픽 허용 · HTTPS 트래픽 허용** 체크 |

3. **VPC 네트워크 → IP 주소** → VM 의 외부 IP 를 **고정 주소로 승격**
   (임시 IP 는 VM 을 껐다 켜면 바뀌어 도메인이 끊깁니다)

## 2. 가비아 — DNS 연결

My가비아 → 도메인 → 해당 도메인 **관리** → **DNS 정보 → DNS 관리 → 설정**

| 타입 | 호스트 | 값 | TTL |
| --- | --- | --- | --- |
| A | `@` | GCP 고정 IP | 600 |
| A | `www` | GCP 고정 IP | 600 |

기존에 `@`·`www` 로 잡힌 A/CNAME(가비아 기본 파킹 등)이 있으면 지웁니다.
반영 확인 (수 분 ~ 수 시간):

```bash
nslookup <도메인>
```

> ★ DNS 가 VM 을 가리키기 전에 caddy 를 띄우면 인증서 발급이 실패하고 재시도합니다.
> 실패가 반복되면 Let's Encrypt 한도에 걸리니, DNS 확인 후 첫 배포를 하세요.

## 3. VM 초기 설정 (SSH 로 한 번)

콘솔의 VM 목록에서 **SSH** 버튼으로 접속합니다.

```bash
# Docker Engine + Compose 플러그인
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER && newgrp docker
docker compose version     # v2.24 이상이어야 compose.gcp.yml 의 !reset·!override 가 동작

# 운영 파일 자리
sudo mkdir -p /srv/haetdeul/ml-models/{ops_auc,ops_whsl,ops_rtl}
sudo chown -R $USER /srv/haetdeul
# ml-backend 컨테이너는 uid 10001 로 돈다 — 모델 폴더를 읽고 쓸 수 있게
sudo chown -R 10001:10001 /srv/haetdeul/ml-models
```

### env 파일

저장소의 `deploy/gcp/env.example` 을 `/srv/haetdeul/.env` 로 옮겨 채웁니다.
LLM 값들은 지금 GitHub Secrets 에 있는 값을 그대로 옮기면 됩니다.

```bash
chmod 600 /srv/haetdeul/.env
```

### ML 모델 올리기

모델(`ops_auc`·`ops_whsl`·`ops_rtl`)은 git 에 없습니다. **배치가 돌던 PC** 의
`haetdeul-ml/ML/20260824/ml_train_kit_2/` 에서 세 폴더를 VM 으로 복사합니다.

```bash
gcloud compute scp --recurse --zone asia-northeast3-a ops_auc ops_whsl ops_rtl <VM이름>:/srv/haetdeul/ml-models/
```

## 4. GitHub Actions 러너를 VM 에 등록

러너가 GitHub 으로 아웃바운드 연결을 맺으므로 22번 외 추가 인바운드 포트는 필요 없습니다.

1. GitHub 저장소 → Settings → Actions → Runners → **New self-hosted runner** → **Linux / x64**
2. 화면의 Download 명령을 VM 에서 그대로 실행 (`~/actions-runner`)
3. 등록 — 라벨이 워크플로의 `runs-on: [self-hosted, linux, gcp]` 와 맞아야 합니다

   ```bash
   ./config.sh --url https://github.com/mpsddd-commits/haetdeul --token <TOKEN> --labels gcp --unattended
   sudo ./svc.sh install && sudo ./svc.sh start
   ```

   (`self-hosted`·`linux` 라벨은 자동으로 붙습니다)

4. **haetdeul-ml 이미지 접근 권한** — 배포 job 의 `GITHUB_TOKEN` 은 haetdeul 저장소
   토큰이라 다른 저장소의 비공개 패키지를 못 받습니다. 둘 중 하나:
   - GitHub → 프로필 → Packages → `haetdeul-ml` → Package settings →
     **Manage Actions access → `haetdeul` 저장소 추가 (Read)**
   - 또는 패키지를 Public 으로 전환

## 5. 배포 전환

저장소 Settings → Secrets and variables → Actions → **Variables** →
`DEPLOY_TARGET` = `gcp`

이후 `main` push 때 Windows `deploy` job 은 건너뛰고 `deploy-gcp` 가 돕니다.
값을 지우면 즉시 Windows 배포로 돌아갑니다.

haetdeul-ml 은 `main` push 때 `.github/workflows/image.yml` 이 이미지를 올리고,
다음 haetdeul 배포가 `:latest` 를 받아 갑니다.

## 6. 확인

```bash
docker ps --filter name=mainproject-
curl -I https://<도메인>
curl https://<도메인>/api/health
docker logs mainproject-caddy --tail 50      # 인증서 발급 로그
```

## 아직 안 한 것

- **DB** — 새로 세우는 중. 서면 `/srv/haetdeul/.env` 의 `DB_*`·`ML_*DATABASE_URL` 만 바꾸고 재배포
- **ML 일일 배치** (`run_batch.py`, 기존 Windows 작업 스케줄러) — VM cron 이전은 DB 이후
- 재학습 백업(`ops_*_교체전_*`)은 볼륨 밖이라 컨테이너 재생성 시 사라진다
