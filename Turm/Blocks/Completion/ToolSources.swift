import Foundation

nonisolated enum KnownTools {
    static let subcommands: [String: [(String, String)]] = [
        "gh": [
            ("pr", "Manage pull requests"), ("issue", "Manage issues"), ("repo", "Manage repositories"), ("run", "View workflow runs"),
            ("workflow", "View workflows"), ("release", "Manage releases"), ("auth", "Authenticate gh"), ("api", "Make an API request"),
            ("gist", "Manage gists"), ("browse", "Open the repository in the browser"), ("codespace", "Manage codespaces"),
            ("config", "Manage configuration"), ("extension", "Manage extensions"), ("search", "Search GitHub"),
            ("secret", "Manage secrets"), ("ssh-key", "Manage SSH keys"), ("status", "Print your GitHub status"),
            ("alias", "Create command shortcuts"), ("cache", "Manage Actions caches"), ("label", "Manage labels"),
            ("org", "Manage organizations"), ("project", "Work with GitHub Projects"), ("variable", "Manage variables"),
        ],
        "aws": [
            ("s3", "Amazon S3"), ("ec2", "Amazon EC2"), ("iam", "IAM"), ("lambda", "AWS Lambda"), ("sts", "Security Token Service"),
            ("cloudformation", "CloudFormation"), ("ecs", "Elastic Container Service"), ("eks", "Elastic Kubernetes Service"),
            ("ecr", "Elastic Container Registry"), ("rds", "Relational Database Service"), ("dynamodb", "DynamoDB"),
            ("sqs", "Simple Queue Service"), ("sns", "Simple Notification Service"), ("logs", "CloudWatch Logs"),
            ("ssm", "Systems Manager"), ("route53", "Route 53"), ("cloudwatch", "CloudWatch"), ("configure", "Configure the CLI"),
            ("sso", "IAM Identity Center"), ("secretsmanager", "Secrets Manager"), ("kms", "Key Management Service"),
        ],
        "terraform": [
            ("init", "Prepare the working directory"), ("plan", "Show changes required"), ("apply", "Create or update infrastructure"),
            ("destroy", "Destroy infrastructure"), ("validate", "Validate the configuration"), ("fmt", "Reformat configuration"),
            ("output", "Show output values"), ("show", "Show state or a plan"), ("state", "Advanced state management"),
            ("workspace", "Workspace management"), ("import", "Import existing infrastructure"), ("taint", "Mark a resource as tainted"),
            ("untaint", "Remove the tainted state"), ("providers", "Show the providers"), ("refresh", "Update the state"),
            ("console", "Interactive console"), ("graph", "Generate a dependency graph"), ("login", "Obtain credentials"),
            ("logout", "Remove credentials"), ("version", "Show the version"), ("test", "Run tests"), ("get", "Install modules"),
            ("force-unlock", "Release a stuck lock"),
        ],
        "pip": [
            ("install", "Install packages"), ("uninstall", "Uninstall packages"), ("freeze", "Output installed packages"),
            ("list", "List installed packages"), ("show", "Show package information"), ("download", "Download packages"),
            ("check", "Verify dependencies"), ("config", "Manage configuration"), ("search", "Search PyPI"), ("wheel", "Build wheels"),
            ("hash", "Compute package hashes"), ("cache", "Inspect the cache"), ("inspect", "Inspect the environment"),
            ("index", "Inspect an index"), ("debug", "Show debug information"),
        ],
        "uv": [
            ("pip", "pip-compatible interface"), ("venv", "Create a virtual environment"), ("run", "Run a command or script"),
            ("add", "Add a dependency"), ("remove", "Remove a dependency"), ("sync", "Sync the environment"), ("lock", "Update the lockfile"),
            ("init", "Create a project"), ("tool", "Run and install tools"), ("python", "Manage Python versions"), ("build", "Build packages"),
            ("publish", "Upload distributions"), ("tree", "Display the dependency tree"), ("export", "Export the lockfile"),
            ("cache", "Manage the cache"), ("self", "Manage uv"), ("version", "Show the project version"),
        ],
        "conda": [
            ("activate", "Activate an environment"), ("deactivate", "Deactivate the environment"), ("create", "Create an environment"),
            ("install", "Install packages"), ("update", "Update packages"), ("remove", "Remove packages"), ("list", "List packages"),
            ("env", "Manage environments"), ("config", "Modify configuration"), ("info", "Show information"), ("search", "Search packages"),
            ("clean", "Remove unused files"), ("run", "Run a command in an environment"), ("init", "Initialize the shell"),
        ],
        "nvm": [
            ("use", "Use a Node version"), ("install", "Install a Node version"), ("uninstall", "Uninstall a Node version"),
            ("alias", "Set an alias"), ("unalias", "Delete an alias"), ("ls", "List installed versions"), ("ls-remote", "List available versions"),
            ("current", "Show the active version"), ("run", "Run a command with a version"), ("exec", "Run in a subshell with a version"),
            ("which", "Show the path of a version"), ("deactivate", "Undo nvm effects"), ("version", "Resolve a version"),
        ],
        "fnm": [
            ("use", "Use a Node version"), ("install", "Install a Node version"), ("uninstall", "Uninstall a Node version"),
            ("default", "Set the default version"), ("list", "List installed versions"), ("list-remote", "List available versions"),
            ("current", "Show the active version"), ("env", "Print shell setup"), ("alias", "Alias a version"), ("unalias", "Remove an alias"),
        ],
        "helm": [
            ("install", "Install a chart"), ("upgrade", "Upgrade a release"), ("uninstall", "Uninstall a release"), ("list", "List releases"),
            ("repo", "Manage chart repositories"), ("search", "Search charts"), ("show", "Show chart information"),
            ("get", "Download release information"), ("template", "Render templates locally"), ("pull", "Download a chart"),
            ("push", "Push a chart"), ("package", "Package a chart"), ("lint", "Lint a chart"), ("create", "Create a chart"),
            ("dependency", "Manage chart dependencies"), ("plugin", "Manage plugins"), ("status", "Show release status"),
            ("history", "Show release history"), ("rollback", "Roll back a release"), ("test", "Run release tests"),
            ("env", "Show helm environment"), ("version", "Show version"), ("verify", "Verify a chart"),
        ],
        "gcloud": [
            ("compute", "Compute Engine"), ("container", "Kubernetes Engine"), ("iam", "IAM"), ("config", "Manage configuration"),
            ("auth", "Manage credentials"), ("projects", "Manage projects"), ("run", "Cloud Run"), ("functions", "Cloud Functions"),
            ("storage", "Cloud Storage"), ("services", "Manage services"), ("sql", "Cloud SQL"), ("app", "App Engine"),
            ("builds", "Cloud Build"), ("logging", "Cloud Logging"), ("secrets", "Secret Manager"), ("pubsub", "Pub/Sub"),
            ("dns", "Cloud DNS"), ("artifacts", "Artifact Registry"), ("kms", "Cloud KMS"), ("init", "Initialize gcloud"),
            ("info", "Show environment information"), ("components", "Manage components"), ("version", "Show version"),
        ],
        "az": [
            ("login", "Log in"), ("logout", "Log out"), ("account", "Manage subscriptions"), ("group", "Manage resource groups"),
            ("vm", "Virtual machines"), ("aks", "Kubernetes Service"), ("acr", "Container Registry"), ("storage", "Storage"),
            ("webapp", "Web apps"), ("functionapp", "Function apps"), ("network", "Networking"), ("keyvault", "Key Vault"),
            ("sql", "Azure SQL"), ("monitor", "Monitor"), ("role", "Role assignments"), ("ad", "Active Directory"),
            ("config", "Manage CLI configuration"), ("extension", "Manage extensions"), ("upgrade", "Upgrade the CLI"),
            ("version", "Show version"), ("resource", "Manage resources"), ("provider", "Resource providers"),
            ("cosmosdb", "Cosmos DB"), ("container", "Container instances"), ("vmss", "Scale sets"), ("deployment", "Deployments"),
        ],
        "volta": [
            ("install", "Install a tool"), ("uninstall", "Remove a tool"), ("pin", "Pin a tool in the project"),
            ("list", "List installed tools"), ("fetch", "Fetch a tool"), ("run", "Run with specific versions"),
            ("which", "Locate a binary"), ("completions", "Generate completions"), ("setup", "Set up volta"),
        ],
        "pyenv": [
            ("versions", "List installed versions"), ("version", "Show the active version"), ("global", "Set the global version"),
            ("local", "Set the local version"), ("shell", "Set the shell version"), ("install", "Install a version"),
            ("uninstall", "Uninstall a version"), ("which", "Show the path of a command"), ("prefix", "Show the prefix of a version"),
            ("rehash", "Rebuild shims"), ("virtualenv", "Create a virtualenv"),
        ],
    ]

    static let aliases: [String: String] = [
        "tofu": "terraform", "pip3": "pip", "mamba": "conda", "micromamba": "conda",
    ]

    static let nested: [String: [(String, String)]] = [
        "gh pr": [
            ("create", "Create a pull request"), ("list", "List pull requests"), ("view", "View a pull request"),
            ("checkout", "Check out a pull request"), ("merge", "Merge a pull request"), ("close", "Close a pull request"),
            ("reopen", "Reopen a pull request"), ("diff", "View changes"), ("status", "Show status"), ("review", "Add a review"),
            ("comment", "Add a comment"), ("edit", "Edit a pull request"), ("ready", "Mark as ready"), ("checks", "Show CI status"),
        ],
        "gh issue": [
            ("create", "Create an issue"), ("list", "List issues"), ("view", "View an issue"), ("close", "Close an issue"),
            ("reopen", "Reopen an issue"), ("comment", "Add a comment"), ("edit", "Edit an issue"), ("delete", "Delete an issue"),
            ("status", "Show status"), ("transfer", "Transfer an issue"), ("pin", "Pin an issue"), ("unpin", "Unpin an issue"),
            ("lock", "Lock an issue"), ("unlock", "Unlock an issue"), ("develop", "Manage linked branches"),
        ],
        "gh repo": [
            ("clone", "Clone a repository"), ("create", "Create a repository"), ("fork", "Fork a repository"), ("view", "View a repository"),
            ("list", "List repositories"), ("archive", "Archive a repository"), ("delete", "Delete a repository"),
            ("rename", "Rename a repository"), ("sync", "Sync a repository"), ("edit", "Edit repository settings"),
        ],
        "gh run": [
            ("list", "List workflow runs"), ("view", "View a run"), ("watch", "Watch a run"), ("rerun", "Rerun a run"),
            ("cancel", "Cancel a run"), ("download", "Download artifacts"), ("delete", "Delete a run"),
        ],
        "gh workflow": [
            ("list", "List workflows"), ("view", "View a workflow"), ("run", "Run a workflow"), ("enable", "Enable a workflow"),
            ("disable", "Disable a workflow"),
        ],
        "gh release": [
            ("create", "Create a release"), ("list", "List releases"), ("view", "View a release"), ("delete", "Delete a release"),
            ("download", "Download assets"), ("upload", "Upload assets"), ("edit", "Edit a release"),
        ],
        "gh auth": [
            ("login", "Log in"), ("logout", "Log out"), ("status", "Show status"), ("refresh", "Refresh credentials"),
            ("token", "Print the token"), ("setup-git", "Configure git"),
        ],
        "terraform workspace": [
            ("list", "List workspaces"), ("new", "Create a workspace"), ("select", "Select a workspace"),
            ("delete", "Delete a workspace"), ("show", "Show the current workspace"),
        ],
        "uv pip": [
            ("install", "Install packages"), ("uninstall", "Uninstall packages"), ("list", "List packages"), ("freeze", "Output packages"),
            ("sync", "Sync from requirements"), ("compile", "Compile requirements"), ("show", "Show package information"),
            ("check", "Verify dependencies"), ("tree", "Display the dependency tree"),
        ],
        "conda env": [
            ("create", "Create an environment"), ("list", "List environments"), ("remove", "Remove an environment"),
            ("export", "Export an environment"), ("update", "Update an environment"), ("config", "Configure environments"),
        ],
        "docker container": [
            ("ls", "List containers"), ("run", "Run a container"), ("exec", "Run a command in a container"), ("logs", "Fetch logs"),
            ("stop", "Stop containers"), ("start", "Start containers"), ("restart", "Restart containers"), ("rm", "Remove containers"),
            ("kill", "Kill containers"), ("inspect", "Inspect containers"), ("prune", "Remove stopped containers"),
            ("attach", "Attach to a container"), ("cp", "Copy files"), ("top", "Show processes"), ("stats", "Show resource usage"),
        ],
        "docker image": [
            ("ls", "List images"), ("pull", "Pull an image"), ("push", "Push an image"), ("rm", "Remove images"),
            ("inspect", "Inspect images"), ("history", "Show image history"), ("prune", "Remove unused images"),
            ("tag", "Tag an image"), ("build", "Build an image"), ("save", "Save images to an archive"), ("load", "Load images"),
        ],
        "docker context": [
            ("ls", "List contexts"), ("use", "Set the current context"), ("create", "Create a context"), ("rm", "Remove contexts"),
            ("inspect", "Inspect contexts"), ("show", "Print the current context"), ("update", "Update a context"),
            ("export", "Export a context"), ("import", "Import a context"),
        ],
        "docker volume": [
            ("ls", "List volumes"), ("create", "Create a volume"), ("rm", "Remove volumes"), ("inspect", "Inspect volumes"),
            ("prune", "Remove unused volumes"),
        ],
        "docker network": [
            ("ls", "List networks"), ("create", "Create a network"), ("rm", "Remove networks"), ("inspect", "Inspect networks"),
            ("connect", "Connect a container"), ("disconnect", "Disconnect a container"), ("prune", "Remove unused networks"),
        ],
        "helm repo": [
            ("add", "Add a repository"), ("list", "List repositories"), ("remove", "Remove a repository"),
            ("update", "Update repositories"), ("index", "Generate an index file"),
        ],
        "helm get": [
            ("all", "Everything about a release"), ("hooks", "Release hooks"), ("manifest", "Release manifest"),
            ("notes", "Release notes"), ("values", "Release values"),
        ],
        "helm show": [
            ("all", "All chart information"), ("chart", "Chart definition"), ("crds", "Chart CRDs"), ("readme", "Chart README"),
            ("values", "Chart values"),
        ],
        "helm dependency": [("build", "Rebuild dependencies"), ("list", "List dependencies"), ("update", "Update dependencies")],
        "helm plugin": [
            ("install", "Install a plugin"), ("list", "List plugins"), ("uninstall", "Uninstall a plugin"), ("update", "Update a plugin"),
        ],
        "gcloud config": [
            ("configurations", "Manage named configurations"), ("set", "Set a property"), ("get", "Print a property"),
            ("list", "List properties"), ("unset", "Unset a property"),
        ],
        "gcloud config configurations": [
            ("activate", "Activate a configuration"), ("create", "Create a configuration"), ("delete", "Delete a configuration"),
            ("describe", "Describe a configuration"), ("list", "List configurations"), ("rename", "Rename a configuration"),
        ],
        "az account": [
            ("list", "List subscriptions"), ("show", "Show a subscription"), ("set", "Set the active subscription"),
            ("clear", "Clear subscriptions"), ("list-locations", "List locations"), ("get-access-token", "Get an access token"),
        ],
        "az group": [
            ("create", "Create a resource group"), ("delete", "Delete a resource group"), ("list", "List resource groups"),
            ("show", "Show a resource group"), ("exists", "Check existence"), ("update", "Update a resource group"),
        ],
        "aws s3": [
            ("ls", "List objects"), ("cp", "Copy objects"), ("mv", "Move objects"), ("rm", "Remove objects"), ("sync", "Sync directories"),
            ("mb", "Make a bucket"), ("rb", "Remove a bucket"), ("presign", "Generate a presigned URL"), ("website", "Configure a website"),
        ],
        "aws configure": [
            ("list", "List configuration"), ("get", "Get a value"), ("set", "Set a value"), ("import", "Import credentials"),
            ("list-profiles", "List profiles"), ("sso", "Configure SSO"),
        ],
        "brew services": [
            ("list", "List services"), ("run", "Run a service"), ("start", "Start a service"), ("stop", "Stop a service"),
            ("restart", "Restart a service"), ("cleanup", "Remove unused service files"), ("info", "Show service information"),
            ("kill", "Kill a service"),
        ],
        "kubectl config": [
            ("view", "Show merged kubeconfig"), ("get-contexts", "List contexts"), ("use-context", "Set the current context"),
            ("current-context", "Show the current context"), ("set-context", "Modify a context"), ("delete-context", "Delete a context"),
            ("rename-context", "Rename a context"), ("get-clusters", "List clusters"), ("set-cluster", "Modify a cluster"),
            ("delete-cluster", "Delete a cluster"), ("set-credentials", "Modify a user"), ("get-users", "List users"),
            ("delete-user", "Delete a user"), ("set", "Set a value"), ("unset", "Unset a value"),
        ],
        "kubectl rollout": [
            ("status", "Show rollout status"), ("history", "Show rollout history"), ("undo", "Roll back"), ("restart", "Restart a resource"),
            ("pause", "Pause a resource"), ("resume", "Resume a resource"),
        ],
        "kubectl create": [
            ("namespace", "Create a namespace"), ("deployment", "Create a deployment"), ("service", "Create a service"),
            ("configmap", "Create a config map"), ("secret", "Create a secret"), ("job", "Create a job"), ("cronjob", "Create a cron job"),
            ("role", "Create a role"), ("rolebinding", "Create a role binding"), ("clusterrole", "Create a cluster role"),
            ("clusterrolebinding", "Create a cluster role binding"), ("serviceaccount", "Create a service account"),
            ("ingress", "Create an ingress"), ("quota", "Create a resource quota"),
        ],
    ]

    static let composeSubcommands: [(String, String)] = [
        ("up", "Create and start services"), ("down", "Stop and remove services"), ("ps", "List containers"),
        ("logs", "View service output"), ("build", "Build services"), ("pull", "Pull service images"), ("push", "Push service images"),
        ("restart", "Restart services"), ("start", "Start services"), ("stop", "Stop services"), ("rm", "Remove stopped containers"),
        ("run", "Run a one-off command"), ("exec", "Run a command in a service"), ("config", "Validate and view the config"),
        ("create", "Create containers"), ("kill", "Kill containers"), ("pause", "Pause services"), ("unpause", "Unpause services"),
        ("port", "Print a public port"), ("top", "Show running processes"), ("images", "List images"), ("ls", "List projects"),
        ("cp", "Copy files"), ("events", "Receive events"), ("version", "Show version"), ("watch", "Watch and rebuild"),
    ]

    static func allSubcommands(_ command: String) -> [(String, String)] {
        let key = aliases[command] ?? command
        return KnownCommands.subcommands[key] ?? subcommands[key] ?? []
    }
}

nonisolated extension CommandCompleter {
    static func toolItems(
        command: String, args: [String], positional: [String], value: String, directory: String, env: CompletionEnvironment
    ) -> [CompletionItem]? {
        let tool = KnownTools.aliases[command] ?? command
        switch tool {
        case "gh":
            if positional.count == 1, KnownTools.nested["gh " + positional[0]] != nil {
                return nestedItems(key: "gh " + positional[0], prefix: value)
            }
            return nil
        case "terraform":
            guard positional.first == "workspace" else { return nil }
            if positional.count == 1 { return nestedItems(key: "terraform workspace", prefix: value) }
            guard positional.count == 2, ["select", "delete"].contains(positional[1]) else { return [] }
            return namedItems(terraformWorkspaces(directory: directory, env: env), kind: .workspace, detail: "workspace", prefix: value)
        case "pip":
            guard let verb = positional.first, ["uninstall", "show"].contains(verb) else { return nil }
            return namedItems(pythonPackages(directory: directory, env: env), kind: .package, detail: "installed package", prefix: value)
        case "uv":
            guard positional.first == "pip" else { return nil }
            if positional.count == 1 { return nestedItems(key: "uv pip", prefix: value) }
            guard positional.count >= 2, ["uninstall", "show"].contains(positional[1]) else { return nil }
            return namedItems(pythonPackages(directory: directory, env: env), kind: .package, detail: "installed package", prefix: value)
        case "conda":
            if positional.first == "env" {
                return positional.count == 1 ? nestedItems(key: "conda env", prefix: value) : nil
            }
            guard positional.count == 1, positional[0] == "activate" else { return nil }
            return namedItems(condaEnvironments(env), kind: .environment, detail: "conda environment", prefix: value)
        case "nvm":
            guard positional.count == 1, ["use", "uninstall", "run", "exec", "which", "alias", "current"].contains(positional[0]) else { return nil }
            return namedItems(nvmVersions(env), kind: .version, detail: "node version", prefix: value)
        case "fnm":
            guard positional.count == 1, ["use", "default", "uninstall", "alias"].contains(positional[0]) else { return nil }
            return namedItems(fnmVersions(env), kind: .version, detail: "node version", prefix: value)
        case "pyenv":
            guard positional.count == 1, ["global", "local", "shell", "uninstall", "prefix"].contains(positional[0]) else { return nil }
            return namedItems(pyenvVersions(env), kind: .version, detail: "python version", prefix: value)
        default:
            return cloudItems(command: command, args: args, positional: positional, value: value, directory: directory, env: env)
        }
    }

    static func sourceOptionItems(
        command: String, option: String, current: ShellToken?, args: [String], directory: String, env: CompletionEnvironment
    ) -> [CompletionItem]? {
        let value = current?.value ?? ""
        switch (KnownTools.aliases[command] ?? command, option) {
        case ("kubectl", "-n"), ("kubectl", "--namespace"):
            return namedItems(kubeNamespaces(env, args: args), kind: .namespace, detail: "namespace", prefix: value)
        case ("kubectl", "--context"):
            return namedItems(kubeConfig(env).contexts.map(\.name), kind: .context, detail: "context", prefix: value)
        case ("kubectl", "--cluster"):
            return namedItems(kubeConfig(env).clusters, kind: .context, detail: "cluster", prefix: value)
        case ("kubectl", "--user"):
            return namedItems(kubeConfig(env).users, kind: .user, detail: "kubeconfig user", prefix: value)
        case ("kubectl", "-o"), ("kubectl", "--output"):
            let formats = ["json", "yaml", "name", "wide", "jsonpath=", "custom-columns=", "go-template="]
            return formats.filter { $0.hasPrefix(value) }.map {
                CompletionItem(insert: $0, kind: .choice, terminator: $0.hasSuffix("=") ? "" : " ")
            }
        case ("docker", "--context"), ("docker", "-c"):
            return namedItems(dockerContextNames(env), kind: .context, detail: "docker context", prefix: value)
        case ("docker", "-v"), ("docker", "--volume"), ("docker", "--network"), ("docker", "--net"), ("docker", "--volumes-from"):
            return dockerOptionItems(option: option, current: current, args: args, directory: directory, env: env)
        case ("aws", "--profile"):
            return namedItems(awsProfiles(env), kind: .profile, detail: "aws profile", prefix: value)
        case ("conda", "-n"), ("conda", "--name"):
            return namedItems(condaEnvironments(env), kind: .environment, detail: "conda environment", prefix: value)
        default:
            return cloudOptionItems(command: command, option: option, current: current, args: args, directory: directory, env: env)
        }
    }

    static func directoryNames(_ path: String, env: CompletionEnvironment) -> [String] {
        (env.directoryEntries(atPath: path) ?? []).filter { $0.isDirectory && !$0.name.hasPrefix(".") }.map(\.name)
    }

    static func awsProfiles(_ env: CompletionEnvironment) -> [String] {
        let config = env.variables["AWS_CONFIG_FILE"] ?? env.homeDirectory + "/.aws/config"
        let credentials = env.variables["AWS_SHARED_CREDENTIALS_FILE"] ?? env.homeDirectory + "/.aws/credentials"
        var profiles: [String] = []
        func scan(_ path: String, isConfig: Bool) {
            for raw in (env.readText(atPath: path) ?? "").components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
                var name = String(line[line.index(after: line.startIndex)..<close]).trimmingCharacters(in: .whitespaces)
                if isConfig {
                    if name.hasPrefix("profile ") { name = String(name.dropFirst("profile ".count)).trimmingCharacters(in: .whitespaces) }
                    else if name != "default" { continue }
                }
                if !name.isEmpty { profiles.append(name) }
            }
        }
        scan(config, isConfig: true)
        scan(credentials, isConfig: false)
        return Array(Set(profiles)).sorted()
    }

    static func terraformWorkspaces(directory: String, env: CompletionEnvironment) -> [String] {
        var names = ["default"] + directoryNames(directory + "/terraform.tfstate.d", env: env)
        if let current = env.readText(atPath: directory + "/.terraform/environment")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !current.isEmpty {
            names.append(current)
        }
        return Array(Set(names)).sorted()
    }

    static func pythonPackages(directory: String, env: CompletionEnvironment) -> [String] {
        var roots: [String] = []
        if let active = env.variables["VIRTUAL_ENV"] { roots.append(active) }
        roots += [directory + "/.venv", directory + "/venv"]
        var names: [String] = []
        for root in roots {
            for entry in env.directoryEntries(atPath: root + "/lib") ?? [] where entry.isDirectory && entry.name.hasPrefix("python") {
                let site = root + "/lib/" + entry.name + "/site-packages"
                for item in env.directoryEntries(atPath: site) ?? [] {
                    for suffix in [".dist-info", ".egg-info"] where item.name.hasSuffix(suffix) {
                        let base = String(item.name.dropLast(suffix.count))
                        if let dash = base.lastIndex(of: "-") { names.append(String(base[..<dash])) }
                    }
                }
            }
        }
        return Array(Set(names)).sorted()
    }

    static func condaEnvironments(_ env: CompletionEnvironment) -> [String] {
        let home = env.homeDirectory
        var names = ["base"]
        for line in (env.readText(atPath: home + "/.conda/environments.txt") ?? "").components(separatedBy: "\n") {
            let path = line.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { continue }
            let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            if parent == "envs" { names.append((path as NSString).lastPathComponent) }
        }
        var roots = [
            home + "/.conda/envs", home + "/miniconda3/envs", home + "/anaconda3/envs", home + "/miniforge3/envs",
            home + "/mambaforge/envs", "/opt/miniconda3/envs", "/opt/anaconda3/envs", "/opt/homebrew/Caskroom/miniforge/base/envs",
            (env.variables["MAMBA_ROOT_PREFIX"] ?? home + "/micromamba") + "/envs",
        ]
        if let prefix = env.variables["CONDA_PREFIX"] { roots.append(((prefix as NSString).deletingLastPathComponent)) }
        for root in roots { names += directoryNames(root, env: env) }
        return Array(Set(names)).sorted()
    }

    static func nvmVersions(_ env: CompletionEnvironment) -> [String] {
        let base = env.variables["NVM_DIR"] ?? env.homeDirectory + "/.nvm"
        var names = directoryNames(base + "/versions/node", env: env)
        names += (env.directoryEntries(atPath: base + "/alias") ?? []).filter { !$0.isDirectory }.map(\.name)
        return Array(Set(names)).sorted()
    }

    static func fnmVersions(_ env: CompletionEnvironment) -> [String] {
        let home = env.homeDirectory
        var bases = [home + "/.local/share/fnm", home + "/Library/Application Support/fnm"]
        if let custom = env.variables["FNM_DIR"] { bases.insert(custom, at: 0) }
        var names: [String] = []
        for base in bases {
            names += directoryNames(base + "/node-versions", env: env)
            names += directoryNames(base + "/aliases", env: env)
            names += (env.directoryEntries(atPath: base + "/aliases") ?? []).map(\.name)
        }
        return Array(Set(names)).sorted()
    }

    static func pyenvVersions(_ env: CompletionEnvironment) -> [String] {
        let root = env.variables["PYENV_ROOT"] ?? env.homeDirectory + "/.pyenv"
        return Array(Set(directoryNames(root + "/versions", env: env) + ["system"])).sorted()
    }
}
