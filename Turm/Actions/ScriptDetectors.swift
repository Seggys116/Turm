import Foundation

/// Detectors for scripting ecosystems, containers and task runners.
nonisolated enum ScriptDetectors {
    enum PackageManager: String {
        case npm, pnpm, yarn, bun

        func run(_ script: String) -> String {
            "\(rawValue) run \(ShellQuoting.word(script))"
        }

        var execute: String {
            switch self {
            case .npm: "npx"
            case .pnpm: "pnpm exec"
            case .yarn: "yarn"
            case .bun: "bunx"
            }
        }

        var install: String {
            self == .yarn ? "yarn install" : "\(rawValue) install"
        }

        var update: String {
            switch self {
            case .npm: "npm update"
            case .pnpm: "pnpm update"
            case .yarn: "yarn upgrade"
            case .bun: "bun update"
            }
        }

        var outdated: String {
            self == .bun ? "bun outdated" : "\(rawValue) outdated"
        }
    }

    static func packageManager(_ probe: ProjectProbe, manifest: [String: Any]) -> PackageManager {
        if let declared = (manifest["packageManager"] as? String)?.split(separator: "@").first,
           let manager = PackageManager(rawValue: String(declared)) {
            return manager
        }
        if probe.has("pnpm-lock.yaml") || probe.has("pnpm-workspace.yaml") { return .pnpm }
        if probe.has("bun.lockb") || probe.has("bun.lock") { return .bun }
        if probe.has("yarn.lock") { return .yarn }
        return .npm
    }

    private static let frameworks: [(dependency: String, label: String, dev: String, build: String)] = [
        ("next", "Next.js", "next dev", "next build"),
        ("nuxt", "Nuxt", "nuxt dev", "nuxt build"),
        ("astro", "Astro", "astro dev", "astro build"),
        ("@sveltejs/kit", "SvelteKit", "vite dev", "vite build"),
        ("@remix-run/dev", "Remix", "remix dev", "remix build"),
        ("@angular/core", "Angular", "ng serve", "ng build"),
        ("vite", "Vite", "vite", "vite build"),
        ("react-scripts", "Create React App", "react-scripts start", "react-scripts build"),
        ("expo", "Expo", "expo start", "expo export"),
        ("electron", "Electron", "electron .", ""),
    ]

    static func node(_ probe: ProjectProbe) -> Detection? {
        guard let manifest = probe.json("package.json") else { return nil }
        let manager = packageManager(probe, manifest: manifest)
        let scripts = (manifest["scripts"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        let dependencies = ["dependencies", "devDependencies"].flatMap { key in
            (manifest[key] as? [String: Any] ?? [:]).keys
        }
        let framework = frameworks.first { dependencies.contains($0.dependency) }
        let isBun = manager == .bun

        var b = DetectionBuilder(probe: probe, prefix: "node")
        b.add("install", "Install", manager.install, .deps, symbol: "arrow.down.circle", featured: !probe.has("node_modules"))

        func script(_ names: [String]) -> String? { names.first(where: { scripts[$0] != nil }) }

        if let dev = script(["dev", "start", "serve"]) {
            b.add("s.\(dev)", dev == "dev" ? "Dev server" : "Start", manager.run(dev), .run, symbol: dev == "dev" ? "bolt.fill" : "play.fill", featured: true)
        } else if let framework {
            b.add("fw.dev", "Dev server", "\(manager.execute) \(framework.dev)", .run, symbol: "bolt.fill", featured: true)
        }
        if let build = script(["build"]) {
            b.add("s.\(build)", "Build", manager.run(build), .build, featured: true)
        } else if let framework, !framework.build.isEmpty {
            b.add("fw.build", "Build", "\(manager.execute) \(framework.build)", .build, featured: true)
        }
        let realTest = script(["test"]).flatMap { (scripts[$0] ?? "").contains("no test specified") ? nil : $0 }
        if let test = realTest {
            b.add("s.\(test)", "Test", manager.run(test), .test, featured: true)
        }
        if let clean = script(["clean"]) {
            b.add("s.\(clean)", "Clean", manager.run(clean), .clean, featured: true)
        }

        for name in scripts.keys.sorted().prefix(40) {
            if name == "test", realTest == nil { continue }
            let category = ActionClassifier.category(forName: name)
            b.add("s.\(name)", name, manager.run(name), category, symbol: ActionClassifier.symbol(forName: name))
        }

        if scripts["typecheck"] == nil, scripts["type-check"] == nil, probe.has("tsconfig.json") {
            b.add("tsc", "Typecheck", "\(manager.execute) tsc --noEmit", .check, symbol: "checkmark.circle")
        }
        b.add("update", "Update dependencies", manager.update, .deps)
        b.add("outdated", "Outdated packages", manager.outdated, .deps, symbol: "clock.arrow.circlepath")
        b.add("list", "Dependency tree", isBun ? "bun pm ls" : "\(manager.rawValue) list", .deps, symbol: "list.bullet.indent")

        let kind = "\(framework?.label ?? "Node") \u{00B7} \(manager.rawValue)"
        return b.finish(kind: kind)
    }

    static func tauri(_ probe: ProjectProbe) -> Detection? {
        let config = ["src-tauri/tauri.conf.json", "src-tauri/tauri.conf.json5", "src-tauri/Tauri.toml", "tauri.conf.json"]
        guard config.contains(where: probe.has) else { return nil }
        var tool = "cargo tauri"
        if let manifest = probe.json("package.json") {
            let scripts = manifest["scripts"] as? [String: Any] ?? [:]
            let dependencies = ["dependencies", "devDependencies"].flatMap { (manifest[$0] as? [String: Any] ?? [:]).keys }
            if scripts["tauri"] != nil || dependencies.contains("@tauri-apps/cli") {
                tool = "\(packageManager(probe, manifest: manifest).execute) tauri"
            }
        }
        var b = DetectionBuilder(probe: probe, prefix: "tauri")
        b.variant("tauri-bundle", title: "Bundle", [("Release", ""), ("Debug", "--debug")])
        b.add("dev", "Tauri dev", "\(tool) dev", .run, symbol: "bolt.fill", featured: true)
        b.add("build", "Tauri build", "\(tool) build {tauri-bundle}", .build, featured: true)
        b.add("info", "Tauri info", "\(tool) info", .other, symbol: "info.circle")
        if probe.has("src-tauri/Cargo.toml") {
            b.add("check", "Check Rust", "cargo check --manifest-path src-tauri/Cargo.toml", .check)
            b.add("clippy", "Clippy", "cargo clippy --manifest-path src-tauri/Cargo.toml", .check, symbol: "exclamationmark.triangle")
        }
        return b.finish(kind: "Tauri")
    }

    static func deno(_ probe: ProjectProbe) -> Detection? {
        guard let file = probe.first(of: ["deno.json", "deno.jsonc"]) else { return nil }
        let tasks = file == "deno.json" ? (probe.json(file)?["tasks"] as? [String: Any] ?? [:]).keys.sorted() : []
        var b = DetectionBuilder(probe: probe, prefix: "deno")
        for name in tasks.prefix(30) {
            b.add("t.\(name)", name, "deno task \(ShellQuoting.word(name))", ActionClassifier.category(forName: name), symbol: ActionClassifier.symbol(forName: name))
        }
        b.add("test", "Test", "deno test", .test, featured: true)
        b.add("check", "Type check", "deno check .", .check)
        b.add("lint", "Lint", "deno lint", .check, symbol: "checklist")
        b.add("fmt", "Format", "deno fmt", .check, symbol: "text.alignleft")
        return b.finish(kind: "Deno")
    }

    static func python(_ probe: ProjectProbe) -> Detection? {
        let markers = ["pyproject.toml", "requirements.txt", "setup.py", "setup.cfg", "Pipfile", "manage.py", "uv.lock", "poetry.lock"]
        guard probe.first(of: markers) != nil else { return nil }
        let pyproject = probe.text("pyproject.toml") ?? ""
        let requirements = probe.text("requirements.txt") ?? ""
        let configText = pyproject + requirements + (probe.text("tox.ini") ?? "") + (probe.text("setup.cfg") ?? "")

        enum Tool { case uv, poetry, pipenv, plain }
        let tool: Tool = if probe.has("uv.lock") || pyproject.contains("[tool.uv") { .uv }
            else if probe.has("poetry.lock") || pyproject.contains("[tool.poetry") { .poetry }
            else if probe.has("Pipfile") { .pipenv }
            else { .plain }
        let prefix = switch tool {
        case .uv: "uv run "
        case .poetry: "poetry run "
        case .pipenv: "pipenv run "
        case .plain: ""
        }
        let python = tool == .plain ? "python3" : "python"

        var b = DetectionBuilder(probe: probe, prefix: "python")
        let install: String? = switch tool {
        case .uv: "uv sync"
        case .poetry: "poetry install"
        case .pipenv: "pipenv install --dev"
        case .plain:
            if probe.has("requirements.txt") { "python3 -m pip install -r requirements.txt" }
            else if probe.has("pyproject.toml") || probe.has("setup.py") { "python3 -m pip install -e ." }
            else { nil }
        }
        if let install {
            b.add("install", "Install", install, .deps, symbol: "arrow.down.circle", featured: !(probe.has(".venv") || probe.has("venv")))
        }
        if probe.has("manage.py") {
            let manage = "\(prefix)\(python) manage.py"
            b.add("django.run", "Run server", "\(manage) runserver", .run, featured: true)
            b.add("django.migrate", "Migrate", "\(manage) migrate", .deps, symbol: "cylinder.split.1x2")
            b.add("django.makemigrations", "Make migrations", "\(manage) makemigrations", .deps, symbol: "cylinder.split.1x2")
            b.add("django.shell", "Shell", "\(manage) shell", .other, symbol: "terminal")
        } else if let entry = probe.first(of: ["main.py", "app.py", "__main__.py", "run.py"]) {
            b.add("run", "Run", "\(prefix)\(python) \(entry)", .run, featured: true)
        }
        let usesPytest = configText.contains("pytest") || probe.has("pytest.ini") || probe.has("conftest.py") || probe.has("tests/conftest.py")
        if usesPytest {
            b.add("test", "Test", "\(prefix)\(tool == .plain ? "python3 -m " : "")pytest", .test, featured: true)
            b.add("test.fast", "Test (stop on first failure)", "\(prefix)\(tool == .plain ? "python3 -m " : "")pytest -x", .test, symbol: "bolt.badge.xmark")
        } else if probe.has("manage.py") {
            b.add("test", "Test", "\(prefix)\(python) manage.py test", .test, featured: true)
        } else if probe.has("tests") || probe.has("test") {
            b.add("test", "Test", "\(prefix)\(python) -m unittest discover", .test, featured: true)
        }
        if pyproject.contains("ruff") || probe.has("ruff.toml") || probe.has(".ruff.toml") {
            b.add("ruff.check", "Lint", "\(prefix)ruff check .", .check, symbol: "checklist")
            b.add("ruff.fix", "Lint and fix", "\(prefix)ruff check --fix .", .check, symbol: "wand.and.stars")
            b.add("ruff.format", "Format", "\(prefix)ruff format .", .check, symbol: "text.alignleft")
        } else if configText.contains("black") {
            b.add("black", "Format", "\(prefix)black .", .check, symbol: "text.alignleft")
        }
        if pyproject.contains("mypy") || probe.has("mypy.ini") {
            b.add("mypy", "Type check", "\(prefix)mypy .", .check, symbol: "checkmark.circle")
        }
        if pyproject.contains("[build-system]") {
            let build = switch tool {
            case .uv: "uv build"
            case .poetry: "poetry build"
            default: "python3 -m build"
            }
            b.add("build", "Build", build, .build, featured: true)
        }
        switch tool {
        case .uv: b.add("update", "Update dependencies", "uv lock --upgrade", .deps)
        case .poetry: b.add("update", "Update dependencies", "poetry update", .deps)
        case .pipenv: b.add("update", "Update dependencies", "pipenv update", .deps)
        case .plain:
            b.add("venv", "Create virtualenv", "python3 -m venv .venv", .deps, symbol: "shippingbox")
            b.add("outdated", "Outdated packages", "python3 -m pip list --outdated", .deps, symbol: "clock.arrow.circlepath")
        }
        let suffix = switch tool {
        case .uv: " \u{00B7} uv"
        case .poetry: " \u{00B7} poetry"
        case .pipenv: " \u{00B7} pipenv"
        case .plain: ""
        }
        return b.finish(kind: (probe.has("manage.py") ? "Django" : "Python") + suffix)
    }

    static func ruby(_ probe: ProjectProbe) -> Detection? {
        guard probe.has("Gemfile") else { return nil }
        let gemfile = probe.text("Gemfile") ?? ""
        let isRails = probe.has("config/application.rb") || probe.has("bin/rails")
        let usesRSpec = probe.has(".rspec") || probe.has("spec")
        var b = DetectionBuilder(probe: probe, prefix: "ruby")
        b.add("install", "Install", "bundle install", .deps, symbol: "arrow.down.circle")
        if isRails {
            b.add("server", "Run server", "bin/rails server", .run, featured: true)
            b.add("console", "Console", "bin/rails console", .run, symbol: "terminal")
            b.add("migrate", "Migrate", "bin/rails db:migrate", .deps, symbol: "cylinder.split.1x2")
            b.add("routes", "Routes", "bin/rails routes", .other, symbol: "point.topleft.down.to.point.bottomright.curvepath")
        }
        if usesRSpec {
            b.add("test", "Test", "bundle exec rspec", .test, featured: true)
        } else if isRails {
            b.add("test", "Test", "bin/rails test", .test, featured: true)
        } else if probe.has("Rakefile") {
            b.add("test", "Test", "bundle exec rake test", .test, featured: true)
        }
        if probe.has("Rakefile") { b.add("rake", "Rake", "bundle exec rake", .other, symbol: "list.bullet") }
        if gemfile.contains("rubocop") {
            b.add("rubocop", "Lint", "bundle exec rubocop", .check, symbol: "checklist")
            b.add("rubocop.fix", "Lint and fix", "bundle exec rubocop -A", .check, symbol: "wand.and.stars")
        }
        b.add("update", "Update gems", "bundle update", .deps)
        b.add("outdated", "Outdated gems", "bundle outdated", .deps, symbol: "clock.arrow.circlepath")
        return b.finish(kind: isRails ? "Rails" : "Ruby")
    }

    static func php(_ probe: ProjectProbe) -> Detection? {
        guard probe.has("composer.json") else { return nil }
        let manifest = probe.json("composer.json") ?? [:]
        let scripts = (manifest["scripts"] as? [String: Any] ?? [:]).keys
            .filter { !$0.hasPrefix("pre-") && !$0.hasPrefix("post-") }.sorted()
        let isLaravel = probe.has("artisan")
        var b = DetectionBuilder(probe: probe, prefix: "php")
        b.add("install", "Install", "composer install", .deps, symbol: "arrow.down.circle")
        if isLaravel {
            b.add("serve", "Run server", "php artisan serve", .run, featured: true)
            b.add("test", "Test", "php artisan test", .test, featured: true)
            b.add("migrate", "Migrate", "php artisan migrate", .deps, symbol: "cylinder.split.1x2")
        }
        for name in scripts.prefix(30) {
            let category = ActionClassifier.category(forName: name)
            b.add("s.\(name)", name, "composer run \(ShellQuoting.word(name))", category, symbol: ActionClassifier.symbol(forName: name))
        }
        b.add("update", "Update packages", "composer update", .deps)
        b.add("outdated", "Outdated packages", "composer outdated", .deps, symbol: "clock.arrow.circlepath")
        return b.finish(kind: isLaravel ? "Laravel" : "PHP")
    }

    static func docker(_ probe: ProjectProbe) -> Detection? {
        var b = DetectionBuilder(probe: probe, prefix: "docker")
        if probe.first(of: ["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"]) != nil {
            b.add("up", "Up", "docker compose up", .run, symbol: "play.circle", featured: true)
            b.add("up.detached", "Up (detached)", "docker compose up -d", .run, symbol: "play.circle")
            b.add("build", "Build images", "docker compose build", .build, symbol: "shippingbox")
            b.add("down", "Down", "docker compose down", .other, symbol: "stop.circle")
            b.add("logs", "Logs", "docker compose logs -f", .other, symbol: "text.append")
            b.add("ps", "Containers", "docker compose ps", .other, symbol: "list.bullet")
            b.add("pull", "Pull images", "docker compose pull", .deps)
            b.add("restart", "Restart", "docker compose restart", .other, symbol: "arrow.clockwise")
        }
        if probe.has("Dockerfile") {
            let image = probe.folderName.lowercased().filter { $0.isLetter || $0.isNumber || "-_.".contains($0) }
            let tag = image.isEmpty ? "app" : image
            b.add("image", "Build image", "docker build -t \(tag) .", .build, symbol: "shippingbox", featured: !probe.has("compose.yaml") && !probe.has("docker-compose.yml"))
            b.add("image.run", "Run image", "docker run --rm -it \(tag)", .run, symbol: "play.circle")
        }
        return b.finish(kind: "Docker")
    }

    static func just(_ probe: ProjectProbe) -> Detection? {
        guard let file = probe.first(of: ["justfile", "Justfile", ".justfile"]), let text = probe.text(file) else { return nil }
        let pattern = LinePattern(#"^@?([A-Za-z][A-Za-z0-9_-]*)[ \t]*:(?![=:])"#)
        var b = DetectionBuilder(probe: probe, prefix: "just")
        var featuredByCategory = Set<ActionCategory>()
        for line in text.split(separator: "\n") {
            guard let name = pattern.capture(in: line) else { continue }
            let category = ActionClassifier.category(forName: name)
            let featured = category != .other && category != .deps && category != .check && featuredByCategory.insert(category).inserted
            b.add("r.\(name)", name, "just \(ShellQuoting.word(name))", category, symbol: ActionClassifier.symbol(forName: name), featured: featured)
        }
        return b.finish(kind: "Just")
    }

    static func taskfile(_ probe: ProjectProbe) -> Detection? {
        guard let file = probe.first(of: ["Taskfile.yml", "Taskfile.yaml", "taskfile.yml", "taskfile.yaml"]),
              let text = probe.text(file)
        else { return nil }
        var b = DetectionBuilder(probe: probe, prefix: "task")
        var inTasks = false
        var featuredByCategory = Set<ActionCategory>()
        let pattern = LinePattern(#"^(?: {2}|\t)([A-Za-z][A-Za-z0-9_:-]*):"#)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.first?.isWhitespace == false {
                inTasks = line.hasPrefix("tasks:")
                continue
            }
            guard inTasks, let name = pattern.capture(in: line) else { continue }
            let category = ActionClassifier.category(forName: name)
            let featured = category != .other && category != .deps && category != .check && featuredByCategory.insert(category).inserted
            b.add("r.\(name)", name, "task \(ShellQuoting.word(name))", category, symbol: ActionClassifier.symbol(forName: name), featured: featured)
        }
        return b.finish(kind: "Task")
    }

    static func terraform(_ probe: ProjectProbe) -> Detection? {
        guard !probe.files(withExtension: "tf").isEmpty else { return nil }
        var b = DetectionBuilder(probe: probe, prefix: "terraform")
        b.add("init", "Init", "terraform init", .deps, symbol: "arrow.down.circle", featured: !probe.has(".terraform"))
        b.add("validate", "Validate", "terraform validate", .check, symbol: "checkmark.circle", featured: true)
        b.add("plan", "Plan", "terraform plan", .build, symbol: "doc.text.magnifyingglass", featured: true)
        b.add("apply", "Apply", "terraform apply", .run, symbol: "play.fill", featured: true)
        b.add("fmt", "Format", "terraform fmt -recursive", .check, symbol: "text.alignleft")
        b.add("output", "Outputs", "terraform output", .other, symbol: "list.bullet")
        b.add("state", "State", "terraform state list", .other, symbol: "list.bullet.indent")
        return b.finish(kind: "Terraform")
    }
}
