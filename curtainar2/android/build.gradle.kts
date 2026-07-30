allprojects {
    repositories {
        google()
        mavenCentral()
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

// AGP 8 requires every library module to declare a `namespace`, and ignores the
// legacy `package` attribute in AndroidManifest.xml. image_gallery_saver 2.0.3 has
// neither, so we backfill the namespace from its Gradle group. Reflection keeps this
// working regardless of which AGP extension type the plugin registers.
fun Project.backfillAndroidNamespace() {
    val androidExt = extensions.findByName("android") ?: return
    runCatching {
        if (androidExt.javaClass.getMethod("getNamespace").invoke(androidExt) == null) {
            androidExt.javaClass
                .getMethod("setNamespace", String::class.java)
                .invoke(androidExt, group.toString())
        }
    }
}

// Several of the older transitive plugins (image_gallery_saver, the Sceneform-era AR
// plugin) pin Java to 1.8 but let Kotlin default to the Gradle JDK, which AGP rejects as
// "Inconsistent JVM-target compatibility". Pin both sides to 17 everywhere.
val jvmTargetVersion = JavaVersion.VERSION_17

fun Project.alignJvmTargets() {
    val androidExt = extensions.findByName("android")
    if (androidExt != null) {
        runCatching {
            val compileOptions =
                androidExt.javaClass.getMethod("getCompileOptions").invoke(androidExt)
            compileOptions.javaClass
                .getMethod("setSourceCompatibility", Any::class.java)
                .invoke(compileOptions, jvmTargetVersion)
            compileOptions.javaClass
                .getMethod("setTargetCompatibility", Any::class.java)
                .invoke(compileOptions, jvmTargetVersion)
        }
    }
    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
        compilerOptions.jvmTarget.set(
            org.jetbrains.kotlin.gradle.dsl.JvmTarget.fromTarget(jvmTargetVersion.toString()),
        )
    }
}

subprojects {
    // `evaluationDependsOn(":app")` above forces some projects to be evaluated early,
    // and afterEvaluate throws on an already-evaluated project — so handle both cases.
    fun applyFixes() {
        backfillAndroidNamespace()
        alignJvmTargets()
    }
    if (state.executed) applyFixes() else afterEvaluate { applyFixes() }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
