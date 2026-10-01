import Foundation

/// Detectors for compiled-language toolchains and build systems.
nonisolated enum BuildSystemDetectors {
    static func cargo(_ probe: ProjectProbe) -> Detection? {
        guard probe.has("Cargo.toml") else { return nil }
        let manifest = probe.text("Cargo.toml") ?? ""
        let isWorkspace = manifest.contains("[workspace]")
        let hasPackage = manifest.contains("[package]")
        let scope = isWorkspace ? " --workspace" : ""
        var b = DetectionBuilder(probe: probe, prefix: "cargo")
        b.variant("cargo-profile", title: "Profile", [("Debug", ""), ("Release", "--release")])
        b.add("build", "Build", "cargo build\(scope) {cargo-profile}", .build, featured: true)
        if !isWorkspace || hasPackage, manifest.contains("[[bin]]") || probe.has("src/main.rs") || probe.has("src/bin") {
            b.add("run", "Run", "cargo run {cargo-profile}", .run, featured: true)
        }
        b.add("test", "Test", "cargo test\(scope) {cargo-profile}", .test, featured: true)
        b.add("clean", "Clean", "cargo clean", .clean, featured: true)
        b.add("check", "Check", "cargo check\(scope)", .check)
        b.add("clippy", "Clippy", "cargo clippy\(scope) --all-targets", .check, symbol: "exclamationmark.triangle")
        b.add("fmt", "Format", "cargo fmt\(isWorkspace ? " --all" : "")", .check, symbol: "text.alignleft")
        if probe.has("benches") { b.add("bench", "Benchmark", "cargo bench\(scope)", .test, symbol: "speedometer") }
        b.add("doc", "Docs", "cargo doc\(scope) --open", .other, symbol: "book")
        b.add("update", "Update dependencies", "cargo update", .deps)
        b.add("tree", "Dependency tree", "cargo tree", .deps, symbol: "list.bullet.indent")
        return b.finish(kind: "Cargo")
    }

    static func swiftPackage(_ probe: ProjectProbe) -> Detection? {
        guard probe.has("Package.swift") else { return nil }
        let manifest = probe.text("Package.swift") ?? ""
        var b = DetectionBuilder(probe: probe, prefix: "swiftpm")
        b.variant("swift-configuration", title: "Configuration", [("Debug", "-c debug"), ("Release", "-c release")])
        b.add("build", "Build", "swift build {swift-configuration}", .build, featured: true)
        if manifest.contains(".executableTarget") || manifest.contains(".executable(") {
            b.add("run", "Run", "swift run {swift-configuration}", .run, featured: true)
        }
        b.add("test", "Test", "swift test {swift-configuration}", .test, featured: true)
        b.add("clean", "Clean", "swift package clean", .clean, featured: true)
        b.add("resolve", "Resolve packages", "swift package resolve", .deps)
        b.add("update", "Update packages", "swift package update", .deps)
        b.add("describe", "Describe package", "swift package describe", .other, symbol: "info.circle")
        return b.finish(kind: "Swift Package")
    }

    static func xcode(_ probe: ProjectProbe) -> Detection? {
        xcode(probe, destinations: probe.isRemote ? nil : DestinationCache.shared.destinations)
    }

    /// Schemes come from disk and destinations from the cache; remote projects keep the single scheme named after the container.
    static func xcode(_ probe: ProjectProbe, destinations cached: [XcodeDestination]?) -> Detection? {
        let workspace = probe.files(withExtension: "xcworkspace").first
        let project = probe.files(withExtension: "xcodeproj").first
        guard let container = workspace ?? project else { return nil }
        let flag = workspace != nil ? "-workspace" : "-project"
        let name = (container as NSString).deletingPathExtension
        let fallback = XcodeScheme(name: name, symbol: XcodeSchemes.symbol(forExtension: nil))
        var schemes: [XcodeScheme]?
        if !probe.isRemote {
            let found = probe.isVirtual ? [] : XcodeSchemes.discover(container: container, in: probe.directory)
            schemes = found.isEmpty ? [fallback] : found
        }
        let destinations = probe.isVirtual ? [XcodeDestination.mac] : cached
        let scheme = schemes == nil ? ShellQuoting.word(name) : "{xcode-scheme}"
        let destination = destinations == nil ? "" : " {xcode-destination}"
        let base = "\(flag) \(ShellQuoting.word(container)) -scheme \(scheme) -configuration {xcode-configuration}"
        let target = base + destination
        var b = DetectionBuilder(probe: probe, prefix: "xcode")
        if let schemes {
            b.variant("xcode-scheme", title: "Scheme", options: schemes.map {
                ProjectVariant.Option(label: $0.name, value: ShellQuoting.word($0.name), symbol: $0.symbol, tags: $0.platforms)
            })
        }
        if let destinations {
            b.variant("xcode-destination", title: "Destination", options: XcodeDestinations.options(destinations), filter: "xcode-scheme")
        }
        b.variant("xcode-configuration", title: "Configuration", [("Debug", "Debug"), ("Release", "Release")])
        b.add("build", "Build", "xcodebuild \(target) build", .build, featured: true)
        if destinations != nil {
            b.add("run", "Run", XcodeRun.command(arguments: "\(flag) \(ShellQuoting.word(container)) -scheme {xcode-scheme} -configuration {xcode-configuration} {xcode-destination}"), .run, featured: true)
        }
        b.add("test", "Test", "xcodebuild \(target) test", .test, featured: true)
        b.add("clean", "Clean", "xcodebuild \(base) clean", .clean, featured: true)
        b.add("archive", "Archive", "xcodebuild \(target) archive", .build, symbol: "archivebox")
        b.add("list", "List schemes", "xcodebuild -list \(flag) \(ShellQuoting.word(container))", .other, symbol: "list.bullet")
        b.add("open", "Open in Xcode", "open \(ShellQuoting.word(container))", .other, symbol: "hammer")
        return b.finish(kind: "Xcode")
    }

    static func make(_ probe: ProjectProbe) -> Detection? {
        guard let file = probe.first(of: ["GNUmakefile", "Makefile", "makefile"]),
              let text = probe.text(file)
        else { return nil }
        let targets = makeTargets(in: text)
        var b = DetectionBuilder(probe: probe, prefix: "make")

        func pick(_ names: [String]) -> String? { names.first(where: targets.contains) }
        let build = pick(["build", "all"])
        let run = pick(["run", "start", "serve", "dev"])
        let test = pick(["test", "tests", "check"])
        let clean = pick(["clean"])

        b.add("default", build == nil ? "Build" : "make", "make", .build, featured: build == nil)
        if let build { b.add("t.\(build)", "Build", "make \(ShellQuoting.word(build))", .build, featured: true) }
        if let run { b.add("t.\(run)", "Run", "make \(ShellQuoting.word(run))", .run, featured: true) }
        if let test { b.add("t.\(test)", "Test", "make \(ShellQuoting.word(test))", .test, featured: true) }
        if let clean { b.add("t.\(clean)", "Clean", "make \(ShellQuoting.word(clean))", .clean, featured: true) }
        for target in targets.prefix(40) {
            let category = ActionClassifier.category(forName: target)
            b.add("t.\(target)", "make \(target)", "make \(ShellQuoting.word(target))", category, symbol: ActionClassifier.symbol(forName: target))
        }
        b.add("dry", "Dry run", "make -n", .other, symbol: "eye")
        return b.finish(kind: "Make")
    }

    static func makeTargets(in text: String) -> [String] {
        let pattern = LinePattern(#"^([A-Za-z0-9][A-Za-z0-9_./-]*)[ \t]*:(?![=:])"#)
        var seen = Set<String>()
        var result: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let name = pattern.capture(in: line) else { continue }
            if name.hasPrefix(".") || name.contains("%") || name.contains("$") { continue }
            if seen.insert(name).inserted { result.append(name) }
        }
        return result
    }

    static func cmake(_ probe: ProjectProbe) -> Detection? {
        guard probe.has("CMakeLists.txt") else { return nil }
        var b = DetectionBuilder(probe: probe, prefix: "cmake")
        b.variant("cmake-config", title: "Build type", [
            ("Debug", "Debug"), ("Release", "Release"), ("RelWithDebInfo", "RelWithDebInfo"), ("MinSizeRel", "MinSizeRel"),
        ])
        let configure = "cmake -S . -B build -DCMAKE_BUILD_TYPE={cmake-config}"
        b.add("build", "Build", "\(configure) && cmake --build build --config {cmake-config}", .build, featured: true)
        b.add("test", "Test", "ctest --test-dir build --output-on-failure -C {cmake-config}", .test, featured: true)
        b.add("clean", "Clean", "cmake --build build --target clean", .clean, featured: true)
        b.add("configure", "Configure", configure, .build, symbol: "gearshape")
        b.add("install", "Install", "cmake --install build --config {cmake-config}", .deps)
        if probe.has("CMakePresets.json") { b.add("presets", "List presets", "cmake --list-presets", .other, symbol: "list.bullet") }
        return b.finish(kind: "CMake")
    }

    static func meson(_ probe: ProjectProbe) -> Detection? {
        guard probe.has("meson.build") else { return nil }
        var b = DetectionBuilder(probe: probe, prefix: "meson")
        b.variant("meson-buildtype", title: "Build type", [("Debug", "--buildtype=debug"), ("Release", "--buildtype=release")])
        b.add("build", "Build", "meson setup build {meson-buildtype} 2>/dev/null; meson compile -C build", .build, featured: true)
        b.add("test", "Test", "meson test -C build", .test, featured: true)
        b.add("clean", "Clean", "meson compile -C build --clean", .clean, featured: true)
        b.add("reconfigure", "Reconfigure", "meson setup build --reconfigure {meson-buildtype}", .build, symbol: "gearshape")
        return b.finish(kind: "Meson")
    }

    static func go(_ probe: ProjectProbe) -> Detection? {
        guard probe.has("go.mod") else { return nil }
        var b = DetectionBuilder(probe: probe, prefix: "go")
        b.variant("go-race", title: "Race detector", [("Race off", ""), ("Race on", "-race")])
        b.add("build", "Build", "go build {go-race} ./...", .build, featured: true)
        if probe.has("main.go") { b.add("run", "Run", "go run {go-race} .", .run, featured: true) }
        b.add("test", "Test", "go test {go-race} ./...", .test, featured: true)
        b.add("clean", "Clean", "go clean ./...", .clean, featured: true)
        b.add("vet", "Vet", "go vet ./...", .check)
        b.add("fmt", "Format", "go fmt ./...", .check, symbol: "text.alignleft")
        b.add("cover", "Coverage", "go test -cover ./...", .test, symbol: "chart.pie")
        b.add("bench", "Benchmark", "go test -run '^$' -bench=. ./...", .test, symbol: "speedometer")
        b.add("tidy", "Tidy modules", "go mod tidy", .deps)
        b.add("get", "Download modules", "go mod download", .deps)
        return b.finish(kind: "Go")
    }

    static func platformio(_ probe: ProjectProbe) -> Detection? {
        guard probe.has("platformio.ini") else { return nil }
        let text = probe.text("platformio.ini") ?? ""
        let environments = platformioEnvironments(in: text)
        let env = environments.isEmpty ? "" : " {pio-env}"
        var b = DetectionBuilder(probe: probe, prefix: "platformio")
        if !environments.isEmpty {
            let fallback = text.range(of: #"(?m)^[ \t]*default_envs[ \t]*="#, options: .regularExpression) != nil ? "Default envs" : "All envs"
            b.variant("pio-env", title: "Environment", [(fallback, "")] + environments.map { ($0, "-e \(ShellQuoting.word($0))") })
        }
        b.add("build", "Build", "pio run\(env)", .build, featured: true)
        b.add("upload", "Upload", "pio run\(env) -t upload", .run, symbol: "arrow.up.circle", featured: true)
        b.add("monitor", "Monitor", "pio device monitor\(env)", .run, symbol: "antenna.radiowaves.left.and.right", featured: true)
        b.add("test", "Test", "pio test\(env)", .test, featured: probe.has("test"))
        b.add("clean", "Clean", "pio run\(env) -t clean", .clean, featured: true)
        b.add("upload.monitor", "Upload and monitor", "pio run\(env) -t upload -t monitor", .run, symbol: "arrow.up.circle.fill")
        if probe.has("data") { b.add("uploadfs", "Upload filesystem", "pio run\(env) -t uploadfs", .run, symbol: "externaldrive") }
        if text.contains("espidf") { b.add("menuconfig", "Menuconfig", "pio run\(env) -t menuconfig", .other, symbol: "slider.horizontal.3") }
        b.add("check", "Static analysis", "pio check\(env)", .check)
        b.add("compiledb", "Compilation database", "pio run\(env) -t compiledb", .other, symbol: "doc.text")
        b.add("targets", "List targets", "pio run\(env) --list-targets", .other, symbol: "list.bullet")
        b.add("devices", "List devices", "pio device list", .other, symbol: "cable.connector")
        b.add("install", "Install libraries", "pio pkg install\(env)", .deps)
        b.add("update", "Update libraries", "pio pkg update\(env)", .deps)
        return b.finish(kind: "PlatformIO")
    }

    static func platformioEnvironments(in text: String) -> [String] {
        let pattern = LinePattern(#"^[ \t]*\[env:([^\]]+)\]"#)
        var result: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let name = pattern.capture(in: line)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
            if !result.contains(name) { result.append(name) }
        }
        return result
    }

    static func gradle(_ probe: ProjectProbe) -> Detection? {
        guard let script = probe.first(of: ["build.gradle.kts", "build.gradle", "settings.gradle.kts", "settings.gradle"])
        else { return nil }
        let text = probe.text(script) ?? ""
        let tool = probe.has("gradlew") ? "./gradlew" : "gradle"
        var b = DetectionBuilder(probe: probe, prefix: "gradle")
        b.add("build", "Build", "\(tool) build", .build, featured: true)
        if text.contains("application") { b.add("run", "Run", "\(tool) run", .run, featured: true) }
        b.add("test", "Test", "\(tool) test", .test, featured: true)
        b.add("clean", "Clean", "\(tool) clean", .clean, featured: true)
        b.add("assemble", "Assemble", "\(tool) assemble", .build)
        b.add("check", "Check", "\(tool) check", .check)
        b.add("tasks", "List tasks", "\(tool) tasks", .other, symbol: "list.bullet")
        b.add("deps", "Dependencies", "\(tool) dependencies", .deps)
        return b.finish(kind: "Gradle")
    }

    static func maven(_ probe: ProjectProbe) -> Detection? {
        guard probe.has("pom.xml") else { return nil }
        let text = probe.text("pom.xml") ?? ""
        let tool = probe.has("mvnw") ? "./mvnw" : "mvn"
        var b = DetectionBuilder(probe: probe, prefix: "maven")
        b.add("package", "Build", "\(tool) package", .build, featured: true)
        if text.contains("spring-boot-maven-plugin") { b.add("run", "Run", "\(tool) spring-boot:run", .run, featured: true) }
        b.add("test", "Test", "\(tool) test", .test, featured: true)
        b.add("clean", "Clean", "\(tool) clean", .clean, featured: true)
        b.add("compile", "Compile", "\(tool) compile", .build)
        b.add("verify", "Verify", "\(tool) verify", .check)
        b.add("install", "Install", "\(tool) install", .deps)
        b.add("tree", "Dependency tree", "\(tool) dependency:tree", .deps, symbol: "list.bullet.indent")
        return b.finish(kind: "Maven")
    }

    static func dotnet(_ probe: ProjectProbe) -> Detection? {
        let projects = ["csproj", "fsproj", "vbproj"].flatMap(probe.files(withExtension:))
        let solutions = ["sln", "slnx"].flatMap(probe.files(withExtension:))
        guard !projects.isEmpty || !solutions.isEmpty else { return nil }
        var b = DetectionBuilder(probe: probe, prefix: "dotnet")
        b.variant("dotnet-config", title: "Configuration", [("Debug", "-c Debug"), ("Release", "-c Release")])
        b.add("build", "Build", "dotnet build {dotnet-config}", .build, featured: true)
        if !projects.isEmpty { b.add("run", "Run", "dotnet run {dotnet-config}", .run, featured: true) }
        b.add("test", "Test", "dotnet test {dotnet-config}", .test, featured: true)
        b.add("clean", "Clean", "dotnet clean {dotnet-config}", .clean, featured: true)
        if !projects.isEmpty { b.add("watch", "Watch", "dotnet watch run", .run, symbol: "bolt.fill") }
        b.add("restore", "Restore", "dotnet restore", .deps)
        b.add("format", "Format", "dotnet format", .check, symbol: "text.alignleft")
        b.add("publish", "Publish", "dotnet publish {dotnet-config}", .build, symbol: "shippingbox")
        return b.finish(kind: ".NET")
    }

    static func zig(_ probe: ProjectProbe) -> Detection? {
        guard probe.has("build.zig") else { return nil }
        var b = DetectionBuilder(probe: probe, prefix: "zig")
        b.variant("zig-optimize", title: "Optimize", [
            ("Debug", ""), ("ReleaseSafe", "-Doptimize=ReleaseSafe"),
            ("ReleaseFast", "-Doptimize=ReleaseFast"), ("ReleaseSmall", "-Doptimize=ReleaseSmall"),
        ])
        b.add("build", "Build", "zig build {zig-optimize}", .build, featured: true)
        b.add("run", "Run", "zig build run {zig-optimize}", .run, featured: true)
        b.add("test", "Test", "zig build test {zig-optimize}", .test, featured: true)
        b.add("fmt", "Format", "zig fmt .", .check, symbol: "text.alignleft")
        return b.finish(kind: "Zig")
    }

    static func elixir(_ probe: ProjectProbe) -> Detection? {
        guard probe.has("mix.exs") else { return nil }
        let text = probe.text("mix.exs") ?? ""
        var b = DetectionBuilder(probe: probe, prefix: "mix")
        b.add("compile", "Build", "mix compile", .build, featured: true)
        if text.contains(":phoenix") {
            b.add("server", "Run", "mix phx.server", .run, featured: true)
        } else {
            b.add("run", "Run", "mix run", .run, featured: true)
        }
        b.add("test", "Test", "mix test", .test, featured: true)
        b.add("clean", "Clean", "mix clean", .clean, featured: true)
        b.add("iex", "Interactive shell", "iex -S mix", .run, symbol: "terminal")
        b.add("format", "Format", "mix format", .check, symbol: "text.alignleft")
        b.add("deps", "Fetch dependencies", "mix deps.get", .deps)
        return b.finish(kind: "Elixir")
    }

    static func dart(_ probe: ProjectProbe) -> Detection? {
        guard probe.has("pubspec.yaml") else { return nil }
        let isFlutter = (probe.text("pubspec.yaml") ?? "").contains("flutter:")
        let tool = isFlutter ? "flutter" : "dart"
        var b = DetectionBuilder(probe: probe, prefix: "dart")
        if isFlutter {
            b.add("build", "Build", "flutter build", .build, featured: true)
            b.add("run", "Run", "flutter run", .run, featured: true)
        } else {
            b.add("run", "Run", "dart run", .run, featured: true)
        }
        b.add("test", "Test", "\(tool) test", .test, featured: true)
        if isFlutter { b.add("clean", "Clean", "flutter clean", .clean, featured: true) }
        b.add("analyze", "Analyze", "\(tool) analyze", .check)
        b.add("format", "Format", "dart format .", .check, symbol: "text.alignleft")
        b.add("get", "Get packages", "\(tool) pub get", .deps)
        b.add("upgrade", "Upgrade packages", "\(tool) pub upgrade", .deps)
        return b.finish(kind: isFlutter ? "Flutter" : "Dart")
    }

    static func nix(_ probe: ProjectProbe) -> Detection? {
        guard probe.has("flake.nix") else { return nil }
        var b = DetectionBuilder(probe: probe, prefix: "nix")
        b.add("build", "Build", "nix build", .build, featured: true)
        b.add("run", "Run", "nix run", .run, featured: true)
        b.add("check", "Check", "nix flake check", .test, featured: true)
        b.add("develop", "Dev shell", "nix develop", .run, symbol: "terminal")
        b.add("update", "Update flake", "nix flake update", .deps)
        return b.finish(kind: "Nix")
    }
}
