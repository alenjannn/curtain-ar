allprojects {
    repositories {
        google()
        mavenCentral()
        // Unity's exported library declares its bundled artifacts (unity-classes, the ARCore
        // client, the ARM64 loaders) by bare name — `implementation(name: 'arcore_client',
        // ext: 'aar')` — which resolves against a flat directory repository and nothing else.
        // Without this the :unityLibrary module fails to resolve at build time.
        findProject(":unityLibrary")?.let { unityProj ->
            flatDir { dirs(file("${unityProj.projectDir}/libs")) }
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

fun Project.alignCompileSdk() {
    val androidExt = extensions.findByName("android") ?: return
    runCatching {
        // The app and the Unity 6 export both compile against API 36.  Downgrading every
        // non-Unity module here silently overrides app/build.gradle.kts and can make the final
        // resource link fail when Unity contributes API-36 attributes.
        androidExt.javaClass.getMethod("setCompileSdkVersion", Int::class.javaPrimitiveType).invoke(androidExt, 36)
    }
}

subprojects {
    // `evaluationDependsOn(":app")` above forces some projects to be evaluated early,
    // and afterEvaluate throws on an already-evaluated project — so handle both cases.
    fun applyFixes() {
        backfillAndroidNamespace()
        // Unity generates its own module config and means it: :unityLibrary needs
        // compileSdk 36 for androidx.games:games-activity and for the API 36 attributes in
        // its own res/. Clamping it to 34 with everything else fails resource linking.
        if (!path.startsWith(":unityLibrary")) {
            alignCompileSdk()
        }
        alignJvmTargets()
    }
    if (state.executed) applyFixes() else afterEvaluate { applyFixes() }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
