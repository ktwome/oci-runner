# OCI A1 Provisioner — Osaka

Oracle Cloud Japan Central (Osaka)에서 Always Free Ampere A1 인스턴스를 확보할 때까지 GitHub Actions가 안전하게 재시도하는 전용 저장소입니다.

## 고정된 생성 사양

| 항목 | 값 |
|---|---|
| Region | `ap-osaka-1` |
| Shape | `VM.Standard.A1.Flex` |
| CPU / RAM | `1 OCPU / 6 GB` |
| Boot Volume | `50 GB` |
| Image | Ubuntu 24.04 ARM64 |
| 재시도 | 매시 UTC 7분·22분·37분·52분 |
| Instance name | `quant-platform` |

예약 실행은 처음부터 켜지지 않습니다. 먼저 수동 `validate_only` 실행으로 인증·권한·Home Region·subnet·image를 검증한 뒤, capacity 부족이 확인된 경우에만 `OCI_A1_POLLING_ENABLED=true`로 활성화합니다. 인스턴스가 `RUNNING`으로 확인되면 중복 생성을 막고 polling workflow를 자동 비활성화합니다.

## 시작하기

1. OCI에서 API 전용 User/Group과 signing key를 준비합니다.
2. `ktwome-vcn` 안의 public subnet과 선택적 NSG를 준비합니다.
3. GitHub 저장소의 Actions Secrets와 Variables를 등록합니다.
4. `validate_only=true`로 수동 실행합니다.
5. 검증 성공 후 한 번 수동 생성하거나 예약 polling을 켭니다.

필요한 Secret, Variable, IAM Policy와 정확한 활성화 순서는 [설정 가이드](docs/oci-a1-provisioning.md)에 정리되어 있습니다.

## 안전 장치

- Osaka Home Region 불일치 시 생성 중단
- A1 `1 OCPU / 6 GB` 외 사양으로 변경 불가
- public IP를 허용하지 않는 subnet 거부
- 고정 tag 기반 중복 생성 차단
- `Out of host capacity`만 정상 재시도
- public Actions 로그에 Instance OCID와 public IP를 출력하지 않음
- API private key는 파일로 커밋하지 않고 GitHub Secret으로만 전달

> OCI API에는 “Always Free일 때만 생성”하는 플래그가 없습니다. 실행 전 OCI Console의 **Limits, Quotas and Usage**와 기존 A1/Boot Volume 사용량을 반드시 확인하십시오.
