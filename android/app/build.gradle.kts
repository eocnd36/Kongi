plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "io.github.eocnd36.kongi"
    compileSdk = 35

    defaultConfig {
        applicationId = "io.github.eocnd36.kongi"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = (project.findProperty("kongiVersion") as String?) ?: "2.0.0"
        buildConfigField("boolean", "DEMO", "false")
    }

    buildTypes {
        release {
            // Compose는 줄이고 최적화한 release에서 훨씬 부드럽습니다.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // 서명 정보는 저장소에 두지 않습니다. 배포할 때 ~/.gradle/gradle.properties 또는 환경 변수로 넘깁니다.
            // 없으면 debug 키로 서명합니다 (직접 설치해 보는 용도).
            val store = (project.findProperty("kongiKeystore") as String?) ?: System.getenv("KONGI_KEYSTORE")
            signingConfig = if (store != null) {
                signingConfigs.create("release") {
                    storeFile = file(store)
                    storePassword = (project.findProperty("kongiKeystorePassword") as String?) ?: System.getenv("KONGI_KEYSTORE_PASSWORD")
                    keyAlias = (project.findProperty("kongiKeyAlias") as String?) ?: System.getenv("KONGI_KEY_ALIAS") ?: "kongi"
                    keyPassword = (project.findProperty("kongiKeyPassword") as String?) ?: System.getenv("KONGI_KEY_PASSWORD")
                }
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
    buildTypes {
        // 데모 영상용: release와 같지만 Mac에 연결하지 않고 정해진 장면을 재생합니다 (배포하지 않음).
        create("demo") {
            initWith(getByName("release"))
            buildConfigField("boolean", "DEMO", "true")
            signingConfig = signingConfigs.getByName("debug")
            matchingFallbacks += "release"
        }
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

// 가져온 오픈 소스 코드의 라이선스를 앱 안에 넣습니다 (설정 → 오픈 소스 라이선스).
val notices = layout.buildDirectory.dir("generated/notices")
val copyNotices by tasks.registering(Copy::class) {
    from(rootProject.file("../THIRD_PARTY_NOTICES.md"))
    into(notices)
}
android.sourceSets["main"].assets.srcDir(notices)
tasks.named("preBuild") { dependsOn(copyNotices) }

dependencies {
    val compose = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(compose)
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.9.3")
    // 앱 안에서 QR 코드 찍기 (카메라 앱으로 찍어도 바로 열립니다)
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
    // zxing의 카메라 화면이 권한 확인에 씁니다.
    implementation("androidx.core:core-ktx:1.13.1")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
