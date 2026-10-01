import Foundation
import Testing
@testable import Turm

@Suite(.serialized)
final class XcodeSchemeTests {
    private var roots: [URL] = []

    deinit {
        for root in roots { try? FileManager.default.removeItem(at: root) }
    }

    private struct FixtureTarget {
        var id: String
        var name: String
        var productType: String
        var settings: String
    }

    private static let app = "com.apple.product-type.application"
    private static let tests = "com.apple.product-type.bundle.unit-test"
    private static let framework = "com.apple.product-type.framework"

    private func pbxproj(_ targets: [FixtureTarget]) -> String {
        var objects = ""
        for (index, target) in targets.enumerated() {
            objects += """
                \(target.id) = { isa = PBXNativeTarget; name = "\(target.name)"; productType = "\(target.productType)"; buildConfigurationList = CL\(index); };
                CL\(index) = { isa = XCConfigurationList; buildConfigurations = (CC\(index)); };
                CC\(index) = { isa = XCBuildConfiguration; name = Debug; buildSettings = { \(target.settings) }; };

            """
        }
        return """
        // !$*UTF8*$!
        {
            archiveVersion = 1; classes = {}; objectVersion = 56;
            objects = {
            \(objects)
                PRJ = { isa = PBXProject; targets = (\(targets.map(\.id).joined(separator: ", "))); buildConfigurationList = CLP; };
                CLP = { isa = XCConfigurationList; buildConfigurations = (CCP); };
                CCP = { isa = XCBuildConfiguration; name = Debug; buildSettings = { }; };
            };
            rootObject = PRJ;
        }
        """
    }

    private func scheme(name: String, id: String, buildable: String, container: String = "App.xcodeproj") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme LastUpgradeVersion = "1500" version = "1.7">
           <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
              <BuildActionEntries>
                 <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES">
                    <BuildableReference
                       BuildableIdentifier = "primary"
                       BlueprintIdentifier = "\(id)"
                       BuildableName = "\(buildable)"
                       BlueprintName = "\(name)"
                       ReferencedContainer = "container:\(container)">
                    </BuildableReference>
                 </BuildActionEntry>
              </BuildActionEntries>
           </BuildAction>
        </Scheme>
        """
    }

    private func make(_ files: [String: String]) throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("turm-xcode-\(UUID().uuidString)")
        roots.append(root)
        for (name, contents) in files {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.path
    }

    private static let simulators = """
    {"devices":{
      "com.apple.CoreSimulator.SimRuntime.iOS-18-2":[
        {"name":"iPhone 16","udid":"AAAA","state":"Booted","isAvailable":true},
        {"name":"iPad Pro 13-inch","udid":"BBBB","state":"Shutdown","isAvailable":true},
        {"name":"Retired","udid":"XXXX","state":"Shutdown","isAvailable":false}],
      "com.apple.CoreSimulator.SimRuntime.watchOS-11-2":[{"name":"Apple Watch Series 10","udid":"CCCC","state":"Shutdown","isAvailable":true}],
      "com.apple.CoreSimulator.SimRuntime.xrOS-2-2":[{"name":"Apple Vision Pro","udid":"DDDD","state":"Shutdown"}],
      "com.apple.CoreSimulator.SimRuntime.tvOS-18-2":[{"name":"Apple TV","udid":"EEEE","state":"Shutdown"}]}}
    """

    private static let devices = """
    {"result":{"devices":[
      {"identifier":"CORE-1","hardwareProperties":{"udid":"U1","platform":"iOS","deviceType":"iPhone"},
       "deviceProperties":{"name":"Work iPhone","osVersionNumber":"18.1"},"connectionProperties":{"tunnelState":"connected"}},
      {"identifier":"CORE-2","hardwareProperties":{"udid":"U2","platform":"iOS","deviceType":"iPad"},
       "deviceProperties":{"name":"Sleeping iPad"},"connectionProperties":{"tunnelState":"disconnected"}}]}}
    """

    private let phone = XcodeDestination(kind: .iPhone, platform: "iOS", name: "iPhone 16", id: "AAAA", isSimulator: true, isBooted: true, os: "18.2")

    @Test func productTypeMapsToSymbol() {
        #expect(XcodeSchemes.symbol(buildableName: "Widget.appex") == "puzzlepiece.extension")
        #expect(XcodeSchemes.symbol(buildableName: "Kit.framework") == "shippingbox")
        #expect(XcodeSchemes.symbol(buildableName: "KitTests.xctest") == "checkmark.diamond")
        #expect(XcodeSchemes.symbol(buildableName: "libCore.a") == "books.vertical")
        #expect(XcodeSchemes.symbol(buildableName: "tool") == "terminal")
        #expect(XcodeSchemes.symbol(buildableName: nil) == "cube")
        #expect(XcodeSchemes.symbol(buildableName: "Thing.bundle") == "cube")
    }

    @Test func appSymbolFollowsItsPlatform() {
        #expect(XcodeSchemes.symbol(buildableName: "A.app", platforms: ["macOS"]) == "macwindow")
        #expect(XcodeSchemes.symbol(buildableName: "A.app", platforms: ["iOS"]) == "iphone")
        #expect(XcodeSchemes.symbol(buildableName: "A.app", platforms: ["watchOS"]) == "applewatch")
        #expect(XcodeSchemes.symbol(buildableName: "A.app", platforms: ["tvOS"]) == "appletv")
        #expect(XcodeSchemes.symbol(buildableName: "A.app", platforms: ["visionOS"]) == "visionpro")
        #expect(XcodeSchemes.symbol(buildableName: "A.app", platforms: ["iOS", "macOS"]) == "app")
        #expect(XcodeSchemes.symbol(buildableName: "A.app") == "app")
    }

    @Test func platformsComeFromSupportedPlatformsOrSDKRoot() {
        #expect(XcodeSchemes.platforms(sdkroot: "iphoneos", supported: nil) == ["iOS"])
        #expect(XcodeSchemes.platforms(sdkroot: "auto", supported: "xros iphoneos macosx iphonesimulator") == ["macOS", "iOS", "visionOS"])
        #expect(XcodeSchemes.platforms(sdkroot: "auto", supported: nil).isEmpty)
    }

    @Test func sharedAndUserSchemesAreListed() throws {
        let project = pbxproj([
            .init(id: "AAA", name: "App", productType: Self.app, settings: "SDKROOT = iphoneos;"),
            .init(id: "CCC", name: "Widget", productType: "com.apple.product-type.app-extension", settings: "SDKROOT = iphoneos;"),
        ])
        let path = try make([
            "App.xcodeproj/project.pbxproj": project,
            "App.xcodeproj/xcshareddata/xcschemes/Widget.xcscheme": scheme(name: "Widget", id: "CCC", buildable: "Widget.appex"),
            "App.xcodeproj/xcshareddata/xcschemes/App.xcscheme": scheme(name: "App", id: "AAA", buildable: "App.app"),
            "App.xcodeproj/xcuserdata/me.xcuserdatad/xcschemes/Mine.xcscheme": scheme(name: "Tool", id: "ZZZ", buildable: "tool"),
            "App.xcodeproj/xcuserdata/me.xcuserdatad/xcschemes/xcschememanagement.plist": "{}",
        ])
        let found = XcodeSchemes.discover(container: "App.xcodeproj", in: path)
        #expect(found.map(\.name) == ["App", "Mine", "Widget"])
        #expect(found.map(\.symbol) == ["iphone", "terminal", "puzzlepiece.extension"])
        #expect(found[0].platforms == ["iOS"])
    }

    @Test func schemeFilesWinOverTargetNames() throws {
        let project = pbxproj([
            .init(id: "AAA", name: "App", productType: Self.app, settings: ""),
            .init(id: "BBB", name: "AppTests", productType: Self.tests, settings: ""),
        ])
        let path = try make([
            "App.xcodeproj/project.pbxproj": project,
            "App.xcodeproj/xcshareddata/xcschemes/App.xcscheme": scheme(name: "App", id: "AAA", buildable: "App.app"),
        ])
        #expect(XcodeSchemes.discover(container: "App.xcodeproj", in: path).map(\.name) == ["App"])
    }

    @Test func targetNamesStandInWhenNoSchemeFilesExist() throws {
        let project = pbxproj([
            .init(id: "KKK", name: "Kit", productType: Self.framework, settings: "SDKROOT = auto; SUPPORTED_PLATFORMS = \"iphoneos macosx\";"),
            .init(id: "BBB", name: "AppTests", productType: Self.tests, settings: "SDKROOT = iphoneos;"),
            .init(id: "AAA", name: "App", productType: Self.app, settings: "SDKROOT = macosx;"),
        ])
        let path = try make(["App.xcodeproj/project.pbxproj": project])
        let found = XcodeSchemes.discover(container: "App.xcodeproj", in: path)
        #expect(found.map(\.name) == ["App", "AppTests", "Kit"])
        #expect(found.map(\.symbol) == ["macwindow", "checkmark.diamond", "shippingbox"])
        #expect(found[2].platforms == ["macOS", "iOS"])
    }

    @Test func workspaceListsSchemesOfItsProjectsExceptPods() throws {
        let data = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Workspace version = "1.0">
           <Group location = "container:" name = "Apps">
              <FileRef location = "group:Sub/Inner.xcodeproj"></FileRef>
           </Group>
           <FileRef location = "group:Pods/Pods.xcodeproj"></FileRef>
           <FileRef location = "group:README.md"></FileRef>
        </Workspace>
        """
        let path = try make([
            "Main.xcworkspace/contents.xcworkspacedata": data,
            "Main.xcworkspace/xcshareddata/xcschemes/All.xcscheme": scheme(name: "All", id: "NONE", buildable: "All.framework", container: "Main.xcworkspace"),
            "Sub/Inner.xcodeproj/xcshareddata/xcschemes/Inner.xcscheme": scheme(name: "Inner", id: "NONE", buildable: "Inner.app", container: "Sub/Inner.xcodeproj"),
            "Pods/Pods.xcodeproj/xcshareddata/xcschemes/Pods-App.xcscheme": scheme(name: "Pods-App", id: "NONE", buildable: "libPods.a"),
        ])
        let projects = XcodeSchemes.workspaceProjects(at: (path as NSString).appendingPathComponent("Main.xcworkspace"))
        #expect(projects.map { ($0 as NSString).lastPathComponent } == ["Inner.xcodeproj"])
        #expect(XcodeSchemes.discover(container: "Main.xcworkspace", in: path).map(\.name) == ["All", "Inner"])
    }

    @Test func simulatorsAreParsedFromSimctlJSON() {
        let found = XcodeDestinations.parseSimulators(Self.simulators)
        #expect(found.map(\.name) == ["iPad Pro 13-inch", "iPhone 16", "Apple Watch Series 10", "Apple TV", "Apple Vision Pro"])
        #expect(found.map(\.kind) == [.iPad, .iPhone, .watch, .tv, .vision])
        #expect(found.map(\.isBooted) == [false, true, false, false, false])
        #expect(found[1].id == "AAAA")
        #expect(found[1].os == "18.2")
        #expect(found.map(\.symbol) == ["ipad", "iphone", "applewatch", "appletv", "visionpro"])
        #expect(found[1].detail == "iOS 18.2, Booted")
        #expect(XcodeDestinations.parseSimulators("not json").isEmpty)
    }

    @Test func onlyConnectedDevicesAreParsed() {
        let found = XcodeDestinations.parseDevices(Data(Self.devices.utf8))
        #expect(found.map(\.name) == ["Work iPhone"])
        #expect(found[0].id == "U1")
        #expect(found[0].isSimulator == false)
        #expect(found[0].kind == .iPhone)
    }

    @Test func destinationsFormatTheirXcodebuildArgument() {
        #expect(XcodeDestination.mac.argument == "-destination 'platform=macOS'")
        #expect(phone.argument == "-destination 'platform=iOS Simulator,id=AAAA'")
        let device = XcodeDestination(kind: .watch, platform: "watchOS", name: "Watch", id: "W1")
        #expect(device.argument == "-destination 'platform=watchOS,id=W1'")
        let vision = XcodeDestination(kind: .vision, platform: "visionOS", name: "Pro", id: "V1", isSimulator: true)
        #expect(vision.specifier == "platform=visionOS Simulator,id=V1")
    }

    private func detection(_ files: [String: String], destinations: [XcodeDestination]?) throws -> ProjectSnapshot {
        let path = try make(files)
        let found = try #require(BuildSystemDetectors.xcode(ProjectProbe(directory: path), destinations: destinations))
        var snapshot = ProjectSnapshot()
        snapshot.actions = found.actions
        snapshot.variants = found.variants
        return snapshot
    }

    private func command(_ id: String, in snapshot: ProjectSnapshot, selection: [String: Int] = [:]) throws -> String {
        let action = try #require(snapshot.actions.first { $0.id == id })
        return snapshot.commandLine(for: action, selection: selection, from: action.root)
    }

    @Test func commandsUseTheChosenSchemeAndDestination() throws {
        let files = [
            "My App.xcodeproj/xcshareddata/xcschemes/My App.xcscheme": scheme(name: "My App", id: "A", buildable: "My App.app"),
            "My App.xcodeproj/xcshareddata/xcschemes/Other.xcscheme": scheme(name: "Other", id: "B", buildable: "Other.app"),
        ]
        let snapshot = try detection(files, destinations: [.mac, phone])
        #expect(snapshot.variants.map(\.id) == ["xcode-scheme", "xcode-destination", "xcode-configuration"])
        #expect(try command("xcode.build", in: snapshot)
            == "xcodebuild -project 'My App.xcodeproj' -scheme 'My App' -configuration Debug -destination 'platform=macOS' build")
        let chosen = ["xcode-scheme": 1, "xcode-destination": 1, "xcode-configuration": 1]
        #expect(try command("xcode.test", in: snapshot, selection: chosen)
            == "xcodebuild -project 'My App.xcodeproj' -scheme Other -configuration Release -destination 'platform=iOS Simulator,id=AAAA' test")
        #expect(try command("xcode.archive", in: snapshot, selection: chosen).contains("-destination 'platform=iOS Simulator,id=AAAA' archive"))
        #expect(try !command("xcode.clean", in: snapshot, selection: chosen).contains("-destination"))
    }

    @Test func destinationsFollowThePlatformsOfTheChosenScheme() throws {
        let project = pbxproj([
            .init(id: "MMM", name: "Mac", productType: Self.app, settings: "SDKROOT = macosx;"),
            .init(id: "PPP", name: "Phone", productType: Self.app, settings: "SDKROOT = iphoneos;"),
        ])
        let snapshot = try detection(["App.xcodeproj/project.pbxproj": project], destinations: [.mac, phone])
        let destination = try #require(snapshot.variants.first { $0.id == "xcode-destination" })
        #expect(snapshot.visibleOptions(of: destination, selection: ["xcode-scheme": 0]).map(\.option.label) == ["My Mac"])
        #expect(snapshot.visibleOptions(of: destination, selection: ["xcode-scheme": 1]).map(\.option.label) == ["iPhone 16"])
        let stale = ["xcode-scheme": 0, "xcode-destination": 1]
        #expect(snapshot.selectedOption(of: destination, selection: stale).option.label == "My Mac")
        #expect(try command("xcode.build", in: snapshot, selection: ["xcode-scheme": 1]).contains("-scheme Phone"))
        #expect(try command("xcode.build", in: snapshot, selection: ["xcode-scheme": 1]).contains("id=AAAA"))
    }

    @Test func runBuildsThenLaunchesOnTheDestination() throws {
        let snapshot = try detection(["App.xcodeproj/project.pbxproj": pbxproj([.init(id: "A", name: "App", productType: Self.app, settings: "")])], destinations: [.mac, phone])
        let line = try command("xcode.run", in: snapshot, selection: ["xcode-destination": 1])
        #expect(line.hasPrefix("sh -c '"))
        #expect(line.hasSuffix("turm-run -project App.xcodeproj -scheme App -configuration Debug -destination 'platform=iOS Simulator,id=AAAA'"))
        #expect(line.contains("simctl install"))
        #expect(!XcodeRun.script.contains("'"))
        #expect(snapshot.actions.first { $0.id == "xcode.run" }?.featured == true)
    }

    @Test func withoutDestinationsNothingIsAddedToCommands() throws {
        let snapshot = try detection(["My App.xcodeproj/project.pbxproj": pbxproj([])], destinations: nil)
        #expect(!snapshot.variants.contains { $0.id == "xcode-destination" })
        #expect(!snapshot.actions.contains { $0.id == "xcode.run" })
        #expect(try command("xcode.build", in: snapshot) == "xcodebuild -project 'My App.xcodeproj' -scheme 'My App' -configuration Debug build")
    }

    @Test func remoteProjectsKeepASingleLiteralScheme() throws {
        let remote = ProjectProbe(directory: "/srv/app", remote: RemoteDirectory(path: "/srv/app", entries: [.init(name: "My App.xcodeproj", isDirectory: true)]))
        let found = try #require(BuildSystemDetectors.xcode(remote))
        #expect(found.variants.map(\.id) == ["xcode-configuration"])
        #expect(found.actions.first { $0.id == "xcode.build" }?.command == "xcodebuild -project 'My App.xcodeproj' -scheme 'My App' -configuration {xcode-configuration} build")
        #expect(!found.actions.contains { $0.id == "xcode.run" })
    }

    @Test func variantChoiceSurvivesAChangingOptionList() {
        let suite = UserDefaults(suiteName: "turm-xcode-\(UUID().uuidString)")!
        let before = ProjectVariant(id: "d", title: "D", ecosystem: "x", options: [.init(label: "A", value: "a"), .init(label: "B", value: "b")])
        VariantStore.save(index: 1, variant: "d", roots: ["/x"], value: "b", defaults: suite)
        let after = ProjectVariant(id: "d", title: "D", ecosystem: "x", options: [.init(label: "N", value: "n"), .init(label: "A", value: "a"), .init(label: "B", value: "b")])
        #expect(VariantStore.load(roots: ["/x"], variants: [before], defaults: suite) == ["d": 1])
        #expect(VariantStore.load(roots: ["/x"], variants: [after], defaults: suite) == ["d": 2])
        let gone = ProjectVariant(id: "d", title: "D", ecosystem: "x", options: [.init(label: "A", value: "a")])
        #expect(VariantStore.load(roots: ["/x"], variants: [gone], defaults: suite).isEmpty)
    }
}
