allprojects {
    repositories {
        google()
        mavenCentral()
    }
    // posthog_flutter usa la versión dinámica "3.+" que requiere resolver
    // maven-metadata.xml en red y falla con PKIX/TLS en este entorno. Se fija
    // a la última versión disponible en el caché local de Gradle. Aplica a
    // todos los subproyectos (incluido posthog_flutter) para cubrir tanto
    // debugCompileClasspath como debugRuntimeClasspath.
    // sign_in_with_apple fija androidx.browser:browser:1.5.0, versión que no
    // está en caché y falla con el mismo PKIX/TLS -- se fija a una que sí lo
    // está.
    configurations.all {
        resolutionStrategy {
            force(
                "com.posthog:posthog-android:3.56.2",
                "androidx.browser:browser:1.9.0",
            )
        }
    }
    // sign_in_with_apple fija su propio buildscript con Kotlin 1.7.10 (viejo,
    // anterior al kotlin-android del proyecto raíz: 2.2.20) -- Gradle intenta
    // descargar los jars del toolchain de esa versión concreta
    // (kotlin-daemon-embeddable, kotlin-build-common, etc. 1.7.10) y falla con
    // el mismo PKIX/TLS que posthog arriba. Se fuerza también el classpath de
    // buildscript de cada subproyecto a la versión ya usada/cacheada por el
    // resto del proyecto para evitar esa descarga. Al forzar esto, Gradle
    // re-resuelve el classpath de TODOS los subproyectos (incluidos los que
    // no se tocan), lo que expone el mismo problema con
    // error_prone_annotations:2.27.0 (transitiva de AGP 8.7.3, fijada por
    // in_app_review) -- no está en caché esa versión exacta, así que se fija
    // también a una que sí lo está.
    buildscript {
        configurations.all {
            resolutionStrategy {
                force(
                    "org.jetbrains.kotlin:kotlin-gradle-plugin:2.2.20",
                    "com.google.errorprone:error_prone_annotations:2.30.0",
                )
            }
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// posthog_flutter 4.11.0 y sentry_flutter 8.14.2 fijan kotlinOptions.languageVersion
// = "1.6" en su propio android/build.gradle -- el compilador Kotlin 2.2.20 del
// proyecto ya no soporta compilar con ese language version ("no longer supported;
// use 1.8 or greater"). No hay versión más reciente de ninguno de los dos que lo
// corrija dentro de su rango de pubspec.yaml sin saltar de major version (y migrar
// la API del SDK). Se sobreescribe solo para esos módulos.
subprojects {
    if (name == "posthog_flutter" || name == "sentry_flutter") {
        afterEvaluate {
            tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
                compilerOptions {
                    languageVersion.set(org.jetbrains.kotlin.gradle.dsl.KotlinVersion.KOTLIN_1_9)
                    apiVersion.set(org.jetbrains.kotlin.gradle.dsl.KotlinVersion.KOTLIN_1_9)
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
