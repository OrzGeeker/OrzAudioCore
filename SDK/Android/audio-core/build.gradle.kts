import org.gradle.api.publish.maven.MavenPublication

// Published as com.orzgeeker:audio-core-android:<version>. The full profile
// statically links GPL-family decoders, so the combined AAR is GPL-3.0-or-later
// (the OrzAudioCore core itself remains Apache-2.0).
plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    `maven-publish`
}

val orzAudioCoreVersion = providers.gradleProperty("orzAudioCoreVersion").orElse("1.4.0").get()

android {
    namespace = "com.orzgeeker.audiocore"
    compileSdk = 36

    defaultConfig {
        minSdk = 29
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions { jvmTarget = "17" }

    publishing {
        singleVariant("release") { withSourcesJar() }
    }

    sourceSets["main"].assets.srcDir("src/main/assets")
}

afterEvaluate {
    publishing {
        publications {
            create<MavenPublication>("release") {
                from(components["release"])
                groupId = "com.orzgeeker"
                artifactId = "audio-core-android"
                version = orzAudioCoreVersion
                pom {
                    name.set("OrzAudioCore Android")
                    description.set("Android binding for the OrzAudioCore decoding SDK")
                    url.set("https://github.com/OrzGeeker/OrzAudioCore")
                    licenses {
                        license {
                            name.set("GPL-3.0-or-later")
                            url.set("https://www.gnu.org/licenses/gpl-3.0.html")
                        }
                    }
                    scm { url.set("https://github.com/OrzGeeker/OrzAudioCore") }
                }
            }
        }
        repositories {
            maven { name = "local"; url = uri(layout.buildDirectory.dir("repo")) }
        }
    }
}
