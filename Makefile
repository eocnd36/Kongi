APP := dist/Kongi.app

.PHONY: test l10n build app universal run install icon snapshot apk clean

test: l10n
	swift test

## 모든 언어 파일에 빠진 번역이 없는지 검사
l10n:
	python3 scripts/check-localizations.py

build:
	swift build

## 현재 Mac 아키텍처용 .app + zip
app:
	./scripts/build-app.sh

## Apple Silicon + Intel 유니버설 .app + zip
universal:
	UNIVERSAL=1 ./scripts/build-app.sh

run: app
	-pkill -x Kongi; pkill -x ClaudeUsageBar
	open "$(APP)"

install: app
	-pkill -x Kongi; pkill -x ClaudeUsageBar
	rm -rf "/Applications/Kongi.app" "/Applications/Claude Usage Bar.app"
	cp -R "$(APP)" /Applications/
	open "/Applications/Kongi.app"

## 앱 아이콘을 콩이 그림으로 다시 만들기 (Resources/AppIcon.icns, docs/icon.png)
icon: build
	./scripts/make-icon.sh

## README용 팝오버 스크린샷 (데모 데이터 — 내 계정 정보는 들어가지 않음)
snapshot: build
	cp -R Resources/*.lproj .build/debug/
	.build/debug/ClaudeUsageBar --render-snapshot docs --demo -AppleLanguages "(en)"

## 안드로이드 앱 APK (dist/Kongi-<버전>.apk). Android SDK가 없으면 .tools/에 받아 둡니다.
## 서명 키를 KONGI_KEYSTORE 등으로 넘기면 release, 아니면 debug로 만듭니다.
apk:
	./scripts/build-android.sh

clean:
	rm -rf .build dist android/app/build
