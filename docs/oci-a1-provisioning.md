# OCI Always Free A1 자동 생성 설정 — Osaka

이 구성은 다음 사양의 인스턴스 하나만 검증·생성합니다.

- Shape: `VM.Standard.A1.Flex`
- OCPU: `1`
- 메모리: `6 GB`
- Boot Volume: `50 GB`
- 이미지: A1과 호환되는 최신 표준 Ubuntu 24.04(non-Minimal/non-GPU) 또는 사용자가 고정한 Image OCID
- 재시도: UTC 기준 매시 7분·22분·37분·52분, 즉 15분 간격

Shape과 크기는 GitHub Variable로 바꿀 수 없게 코드에 고정했습니다. 유료 Shape나 과도한 크기로 잘못 생성할 위험을 줄이기 위한 장치입니다.

다만 OCI에는 `Always Free일 때만 생성`하는 옵션이 없습니다. 현재 Free Tier 문서의 보수적인 한도는 A1 합계 `2 OCPU / 12 GB`이며, 기존 A1·Boot Volume 사용량도 합산됩니다. 특히 PAYG 계정에서는 이 워크플로가 무료 여부 자체를 보장하지 않으므로 실행 전에 Console의 Limits, Quotas and Usage와 Block Volume 사용량을 확인해야 합니다.

## 1. Osaka 리전과 네트워크 준비

이 Tenancy의 Home Region은 **Japan Central (Osaka)**이며 리전 식별자는 `ap-osaka-1`입니다. 워크플로에도 이 값을 고정했고, 실제 launch 전에 OCI에서 Home Region을 다시 조회해 일치 여부를 검증합니다. Osaka는 A1 Always Free 대상이지만 Availability Domain이 하나뿐입니다. 따라서 다른 AD로 우회할 수 없으며, capacity가 없으면 Fault Domain을 지정하지 않은 채 다음 예약 실행에서 같은 AD를 재시도합니다.

첨부 화면에서 root compartment의 `ktwome-vcn`(`10.0.0.0/16`)이 `Available`인 것까지는 확인했습니다. 다만 화면에는 subnet이 보이지 않으므로 아래 조건을 충족하는 **public subnet OCID**를 별도로 확인해야 합니다.

Home Region에 다음 조건을 충족하는 public subnet을 준비합니다.

- Internet Gateway와 `0.0.0.0/0` 경로
- VNIC public IP 허용
- SSH 22는 본인 IP 또는 VPN 대역만 ingress 허용
- 공개 서비스가 필요할 때만 80/443 허용
- PostgreSQL 5432와 Redis 6379는 인터넷에 공개하지 않음

가능하면 regional public subnet을 사용하십시오. AD 전용 subnet도 지원하지만 그 경우 워크플로는 해당 AD만 시도합니다. 이 워크플로는 VCN, subnet, route table, NSG, security list를 생성하거나 변경하지 않습니다.

## 2. OCI API 사용자와 IAM Policy

`GithubProvisioner` 같은 전용 OCI Group과 API 전용 User를 만들고 API signing key를 추가합니다. 관리자 계정의 API key를 사용하지 마십시오.

첨부 화면처럼 root compartment의 `ktwome-vcn`과 그 subnet을 그대로 사용하고, 인스턴스도 root compartment에 만들 경우 다음 정책으로 시작할 수 있습니다. Policy는 root compartment에 생성합니다.

```text
Allow group GithubProvisioner to inspect tenancies in tenancy
Allow group GithubProvisioner to inspect compartments in tenancy
Allow group GithubProvisioner to read instance-images in tenancy
Allow group GithubProvisioner to read app-catalog-listing in tenancy
Allow group GithubProvisioner to manage instances in tenancy where request.permission != 'INSTANCE_DELETE'
Allow group GithubProvisioner to use volume-family in tenancy
Allow group GithubProvisioner to use virtual-network-family in tenancy
```

이 구성은 작은 개인 Tenancy에서 기존 root 네트워크를 재사용하는 실용적인 시작점입니다. 나중에 `QuantPlatform` 같은 전용 compartment로 리소스를 분리하면 마지막 세 정책의 범위를 각각 해당 instance/volume/network compartment로 좁히십시오. 첫 수동 검증에서 권한 오류가 나면 오류에 표시된 `request.permission`을 기준으로 조정할 수 있습니다.

VM 접속용 SSH key는 API signing key와 별도로 만듭니다.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/oci_quant_platform -C "quant-platform"
```

OCI API private key와 VM SSH private key는 서로 다른 키입니다. 이 provisioning workflow에는 VM SSH private key를 저장하지 않습니다.

## 3. GitHub Repository Secrets

**Settings → Secrets and variables → Actions → Secrets**에 다음 값을 만듭니다.

| Secret | 값 |
|---|---|
| `OCI_CLI_USER` | API 전용 User OCID |
| `OCI_CLI_TENANCY` | Tenancy OCID |
| `OCI_CLI_FINGERPRINT` | API signing key fingerprint |
| `OCI_CLI_PRIVATE_KEY` | API signing private key PEM 전체 |
| `OCI_SSH_PUBLIC_KEY` | `~/.ssh/oci_quant_platform.pub` 내용 전체 |

어떤 private key도 Issue, commit, workflow 파일, 채팅에 붙여넣지 마십시오. OCI credential은 provisioning step에만 전달되며 checkout이나 self-disable job에는 전달되지 않습니다.

## 4. GitHub Repository Variables

**Settings → Secrets and variables → Actions → Variables**에 다음 값을 만듭니다.

| Variable | 필수 | 값 |
|---|---:|---|
| `OCI_COMPARTMENT_ID` | 예 | 대상 Compartment OCID. Root compartment라면 Tenancy OCID |
| `OCI_SUBNET_ID` | 예 | 같은 리전의 public subnet OCID |
| `OCI_NSG_ID` | 권장 | Subnet과 같은 VCN의 NSG OCID. 비우면 subnet security list만 사용 |
| `OCI_IMAGE_ID` | 아니요 | A1 호환 표준 Canonical Ubuntu 24.04 ARM64 Image OCID. 비우면 실행 시 자동 탐색 |
| `OCI_INSTANCE_NAME` | 아니요 | 기본값 `quant-platform` |
| `OCI_A1_POLLING_ENABLED` | 아니요 | 수동 검증 성공 후에만 `true`로 설정 |

재현 가능한 부팅 환경이 중요하면 `OCI_IMAGE_ID`를 고정하는 편이 낫습니다. 비워두면 OCI가 정기 교체하는 Platform Image 중 실행 시점의 최신 Ubuntu 24.04 A1 호환 이미지를 선택합니다.

## 5. 안전한 활성화 순서

1. `OCI_A1_POLLING_ENABLED`를 만들지 않거나 `false`로 둡니다.
2. **Actions → Provision OCI Always Free A1 → Run workflow**를 엽니다.
3. `validate_only`를 켠 상태로 먼저 실행합니다.
4. 인증, IAM, Home Region, subnet, NSG, image 오류를 모두 해결합니다.
5. `validate_only`를 끄고 수동으로 한 번만 생성 요청을 보냅니다.
6. capacity 부족이면 `OCI_A1_POLLING_ENABLED=true`로 바꿔 예약 재시도를 시작합니다.

`Out of host capacity`만 정상적인 `no_capacity` 결과로 처리합니다. 인증, 권한, 리전, subnet, image, service limit 등 다른 오류는 실패로 노출하여 잘못된 설정을 계속 재시도하지 않습니다.

워크플로가 만든 인스턴스는 다음 tag로 식별합니다.

```json
{
  "managed-by": "github-a1-poller",
  "logical-id": "ktwome-osaka-quant-platform"
}
```

동일 logical-id의 비종료 인스턴스가 하나 있으면 중복 생성하지 않습니다. 같은 이름의 무tag 인스턴스나 logical-id 인스턴스가 둘 이상이면 자동 판단하지 않고 실패합니다. Launch가 접수됐지만 상태가 `PROVISIONING` 또는 `STARTING`이면 `pending`으로 남겨 다음 예약 실행에서 다시 확인하고, `RUNNING`이 확인된 뒤에만 별도 `actions: write` job이 workflow를 비활성화합니다. 이 동작은 schedule뿐 아니라 수동 dispatch도 함께 끄므로 나중에 다시 사용할 때는 **Actions → Provision OCI Always Free A1 → Enable workflow**로 재활성화해야 합니다. `validate_only` 실행은 workflow를 비활성화하지 않습니다.

## 6. 생성 후 확인

Cloud-init은 Docker Engine과 Compose plugin을 설치하고 `/opt/quant-platform`을 만듭니다. 저장소 코드 배포와 애플리케이션 Secret 설치는 하지 않습니다.

배포 전에 다음을 확인하십시오.

```bash
sudo cloud-init status --wait
docker version
docker compose version
```

또한 다음 조건을 확인해야 합니다.

- 모든 Docker image와 native dependency가 `linux/arm64` 지원
- `.env`, DB credential, 배포용 SSH private key를 cloud-init에 포함하지 않음
- 상태 데이터는 Boot Volume 밖에도 백업

비공개 저장소의 scheduled job은 GitHub Actions 사용 시간을 소모합니다. 15분 주기는 30일 기준 최대 2,880회의 예약 실행이므로 이 저장소는 Secret이 커밋되지 않는 **public repository**로 운영하는 구성을 권장합니다. 비공개로 만들 경우 계정의 Actions 한도와 예상 실행 시간을 먼저 확인하십시오.

Public repository에 60일 동안 아무 활동이 없으면 GitHub가 scheduled workflow를 자동 비활성화할 수 있습니다. 대기가 길어질 경우 Actions 화면에서 workflow 상태를 확인하고 필요하면 다시 활성화하십시오. Actions 요약과 로그에는 public IP나 Instance OCID를 출력하지 않으므로 생성 결과의 상세 값은 OCI Console에서 확인합니다.

## 공식 참고 문서

- [OCI Free Tier와 Home Region/A1 한도](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier.htm)
- [OCI 리전 목록 — Osaka `ap-osaka-1`, 1 AD](https://docs.oracle.com/en-us/iaas/Content/General/Concepts/regions.htm)
- [OCI Always Free A1 한도와 리전 예외](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)
- [OCI CLI instance launch 옵션](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/compute/instance/launch.html)
- [OCI Out of host capacity 대응](https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/troubleshooting-out-of-host-capacity.htm)
- [GitHub scheduled workflow 동작](https://docs.github.com/actions/using-workflows/events-that-trigger-workflows#schedule)
- [GitHub workflow disable API](https://docs.github.com/rest/actions/workflows#disable-a-workflow)
- [GitHub Actions billing](https://docs.github.com/billing/managing-billing-for-github-actions/about-billing-for-github-actions)
