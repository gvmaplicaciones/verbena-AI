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
    configurations.all {
        resolutionStrategy {
            force("com.posthog:posthog-android:3.56.2")
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
