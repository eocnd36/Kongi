#!/usr/bin/env bash
# Kongi를 늘 같은 인증서로 서명하기 위한 자체 서명 인증서를 한 번 만듭니다 (Apple 개발자 계정 없이).
# 같은 인증서로 서명한 앱은 업데이트해도 macOS가 같은 앱으로 알아봐 손쉬운 사용 권한이 유지됩니다.
# (Gatekeeper 경고는 지금과 같습니다. 그것까지 없애려면 Developer ID + 공증이 필요합니다.)
#
#   ./scripts/make-signing-cert.sh
#
# 만든 파일은 ~/.kongi/ 에만 있습니다. 절대 저장소에 올리지 마세요.
# GitHub Actions에서도 같은 인증서를 쓰려면 출력되는 두 값을 저장소 Secrets에 넣습니다:
#   KONGI_CODESIGN_P12 (base64), KONGI_CODESIGN_PASSWORD
set -euo pipefail
DIR="$HOME/.kongi"
P12="$DIR/kongi-codesign.p12"
PASS_FILE="$DIR/kongi-codesign.pass"
if [[ -f "$P12" ]]; then
  echo "$P12 already exists. Keep using it — a new certificate resets the permission once more." >&2
  exit 1
fi
mkdir -p "$DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<'CNF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Kongi Self-Signed
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
PASSWORD="$(openssl rand -hex 24)"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 7300 -config "$WORK/cert.cnf" 2>/dev/null
# macOS의 security가 읽을 수 있는 형식으로 (OpenSSL 3은 -legacy가 필요)
openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$P12" -passout "pass:$PASSWORD" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$P12" -passout "pass:$PASSWORD"
printf '%s' "$PASSWORD" > "$PASS_FILE"
chmod 600 "$P12" "$PASS_FILE"
echo "Created $P12"
echo "For GitHub Actions, add these repository secrets:"
echo "  KONGI_CODESIGN_PASSWORD = (contents of $PASS_FILE)"
echo "  KONGI_CODESIGN_P12      = output of: base64 -i $P12 | pbcopy"
