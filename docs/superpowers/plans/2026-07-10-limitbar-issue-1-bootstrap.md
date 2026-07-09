# LimitBar Issue 1 Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bootstrap LimitBar as a native macOS 14+ menu bar app with a separate testable core package.

**Architecture:** A small SwiftUI app target owns native UI shell concerns: menu bar item, monitoring popover, and settings scene. A local Swift package named `LimitBarCore` owns the first testable model used by the shell and remains free of SwiftUI.

**Tech Stack:** Swift 6 toolchain, Swift Package Manager, SwiftUI, `MenuBarExtra`, manually checked-in Xcode project metadata.

## Global Constraints

- Target macOS 14 or newer.
- Do not add provider data, persistence, credentials, notifications, sounds, or urgent alerts.
- Keep `LimitBarCore` independent from SwiftUI and AppKit.
- Use test-first development for core behavior.
- Document exact local setup, build, and test commands in `README.md`.
- Local environment note: this machine has Command Line Tools selected but does not have full Xcode available to run `xcodebuild`.

---

## File Structure

- `LimitBarCore/Package.swift` defines the standalone core package and test target.
- `LimitBarCore/Sources/LimitBarCore/AppStatus.swift` defines the initial status model used by the app shell.
- `LimitBarCore/Tests/LimitBarCoreTests/AppStatusTests.swift` tests the initial status label, symbol, and accessibility description.
- `LimitBar/LimitBarApp.swift` defines the SwiftUI app entry point, menu bar item, popover, and settings scene.
- `LimitBar/MonitoringPopoverView.swift` defines the empty monitoring popover shell.
- `LimitBar/LimitBarSettingsView.swift` defines the empty settings shell.
- `LimitBar.xcodeproj/project.pbxproj` defines the native macOS app target and links the local `LimitBarCore` package product.
- `README.md` documents the project shape and local commands.

---

### Task 1: Core Package Status Model

**Files:**
- Create: `LimitBarCore/Package.swift`
- Create: `LimitBarCore/Sources/LimitBarCore/AppStatus.swift`
- Create: `LimitBarCore/Tests/LimitBarCoreTests/AppStatusTests.swift`

**Interfaces:**
- Consumes: No project code.
- Produces: `public struct AppStatus`, `public static let initial`, `public var menuBarText: String`, `public var symbolName: String`, `public var accessibilityDescription: String`.

- [ ] **Step 1: Create package directories**

Run: `mkdir -p LimitBarCore/Sources/LimitBarCore LimitBarCore/Tests/LimitBarCoreTests`

Expected: directories exist.

- [ ] **Step 2: Create the package manifest**

Create `LimitBarCore/Package.swift`:

```swift
// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LimitBarCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "LimitBarCore",
            targets: ["LimitBarCore"]
        )
    ],
    targets: [
        .target(name: "LimitBarCore"),
        .testTarget(
            name: "LimitBarCoreTests",
            dependencies: ["LimitBarCore"]
        )
    ]
)
```

- [ ] **Step 3: Write the failing test**

Create `LimitBarCore/Tests/LimitBarCoreTests/AppStatusTests.swift`:

```swift
import Testing
@testable import LimitBarCore

@Suite("AppStatus")
struct AppStatusTests {
    @Test("initial status is compact and neutral")
    func initialStatusIsCompactAndNeutral() {
        let status = AppStatus.initial

        #expect(status.menuBarText == "LimitBar")
        #expect(status.symbolName == "gauge.with.dots.needle.bottom.50percent")
        #expect(status.accessibilityDescription == "LimitBar usage monitor")
    }
}
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore`

Expected: FAIL because `AppStatus` is not defined.

- [ ] **Step 5: Implement the minimal core model**

Create `LimitBarCore/Sources/LimitBarCore/AppStatus.swift`:

```swift
public struct AppStatus: Equatable, Sendable {
    public let menuBarText: String
    public let symbolName: String
    public let accessibilityDescription: String

    public init(
        menuBarText: String,
        symbolName: String,
        accessibilityDescription: String
    ) {
        self.menuBarText = menuBarText
        self.symbolName = symbolName
        self.accessibilityDescription = accessibilityDescription
    }

    public static let initial = AppStatus(
        menuBarText: "LimitBar",
        symbolName: "gauge.with.dots.needle.bottom.50percent",
        accessibilityDescription: "LimitBar usage monitor"
    )
}
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore`

Expected: PASS with 1 test and 0 failures.

---

### Task 2: Native Menu Bar App Shell

**Files:**
- Create: `LimitBar/LimitBarApp.swift`
- Create: `LimitBar/MonitoringPopoverView.swift`
- Create: `LimitBar/LimitBarSettingsView.swift`
- Create: `LimitBar.xcodeproj/project.pbxproj`
- Create: `LimitBar.xcodeproj/xcshareddata/xcschemes/LimitBar.xcscheme`

**Interfaces:**
- Consumes: `LimitBarCore.AppStatus.initial` from Task 1.
- Produces: `LimitBarApp`, `MonitoringPopoverView`, and `LimitBarSettingsView` for the native macOS shell.

- [ ] **Step 1: Create app directories**

Run: `mkdir -p LimitBar LimitBar.xcodeproj`

Expected: directories exist.

- [ ] **Step 2: Add the SwiftUI app entry point**

Create `LimitBar/LimitBarApp.swift`:

```swift
import SwiftUI
import LimitBarCore

@main
struct LimitBarApp: App {
    private let status = AppStatus.initial

    var body: some Scene {
        MenuBarExtra {
            MonitoringPopoverView()
        } label: {
            Label(status.menuBarText, systemImage: status.symbolName)
                .labelStyle(.titleAndIcon)
                .accessibilityLabel(status.accessibilityDescription)
        }
        .menuBarExtraStyle(.window)

        Settings {
            LimitBarSettingsView()
        }
    }
}
```

- [ ] **Step 3: Add the monitoring popover shell**

Create `LimitBar/MonitoringPopoverView.swift`:

```swift
import SwiftUI

struct MonitoringPopoverView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("LimitBar")
                    .font(.title2.weight(.semibold))
                Text("Provider usage will appear here as integrations are added.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("No provider data configured yet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 320, alignment: .leading)
    }
}

#Preview {
    MonitoringPopoverView()
}
```

- [ ] **Step 4: Add the settings shell**

Create `LimitBar/LimitBarSettingsView.swift`:

```swift
import SwiftUI

struct LimitBarSettingsView: View {
    var body: some View {
        Form {
            Section("Setup") {
                Text("Provider settings will be configured in a later issue.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 420, height: 220)
    }
}

#Preview {
    LimitBarSettingsView()
}
```

- [ ] **Step 5: Add the Xcode project metadata**

Create `LimitBar.xcodeproj/project.pbxproj`:

```text
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 60;
	objects = {

/* Begin PBXBuildFile section */
		AA0000000000000000000001 /* LimitBarApp.swift in Sources */ = {isa = PBXBuildFile; fileRef = AA0000000000000000000011 /* LimitBarApp.swift */; };
		AA0000000000000000000002 /* MonitoringPopoverView.swift in Sources */ = {isa = PBXBuildFile; fileRef = AA0000000000000000000012 /* MonitoringPopoverView.swift */; };
		AA0000000000000000000003 /* LimitBarSettingsView.swift in Sources */ = {isa = PBXBuildFile; fileRef = AA0000000000000000000013 /* LimitBarSettingsView.swift */; };
		AA0000000000000000000004 /* LimitBarCore in Frameworks */ = {isa = PBXBuildFile; productRef = AA0000000000000000000061 /* LimitBarCore */; };
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		AA0000000000000000000011 /* LimitBarApp.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = LimitBarApp.swift; sourceTree = "<group>"; };
		AA0000000000000000000012 /* MonitoringPopoverView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MonitoringPopoverView.swift; sourceTree = "<group>"; };
		AA0000000000000000000013 /* LimitBarSettingsView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = LimitBarSettingsView.swift; sourceTree = "<group>"; };
		AA0000000000000000000021 /* LimitBar.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = LimitBar.app; sourceTree = BUILT_PRODUCTS_DIR; };
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		AA0000000000000000000031 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				AA0000000000000000000004 /* LimitBarCore in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		AA0000000000000000000040 = {
			isa = PBXGroup;
			children = (
				AA0000000000000000000041 /* LimitBar */,
				AA0000000000000000000042 /* Products */,
			);
			sourceTree = "<group>";
		};
		AA0000000000000000000041 /* LimitBar */ = {
			isa = PBXGroup;
			children = (
				AA0000000000000000000011 /* LimitBarApp.swift */,
				AA0000000000000000000012 /* MonitoringPopoverView.swift */,
				AA0000000000000000000013 /* LimitBarSettingsView.swift */,
			);
			path = LimitBar;
			sourceTree = "<group>";
		};
		AA0000000000000000000042 /* Products */ = {
			isa = PBXGroup;
			children = (
				AA0000000000000000000021 /* LimitBar.app */,
			);
			name = Products;
			sourceTree = "<group>";
		};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		AA0000000000000000000050 /* LimitBar */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = AA0000000000000000000090 /* Build configuration list for PBXNativeTarget "LimitBar" */;
			buildPhases = (
				AA0000000000000000000032 /* Sources */,
				AA0000000000000000000031 /* Frameworks */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = LimitBar;
			packageProductDependencies = (
				AA0000000000000000000061 /* LimitBarCore */,
			);
			productName = LimitBar;
			productReference = AA0000000000000000000021 /* LimitBar.app */;
			productType = "com.apple.product-type.application";
		};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		AA0000000000000000000070 /* Project object */ = {
			isa = PBXProject;
			attributes = {
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1600;
				LastUpgradeCheck = 1600;
				TargetAttributes = {
					AA0000000000000000000050 = {
						CreatedOnToolsVersion = 16.0;
					};
				};
			};
			buildConfigurationList = AA0000000000000000000080 /* Build configuration list for PBXProject "LimitBar" */;
			compatibilityVersion = "Xcode 15.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = AA0000000000000000000040;
			minimizedProjectReferenceProxies = 1;
			packageReferences = (
				AA0000000000000000000060 /* XCLocalSwiftPackageReference "LimitBarCore" */,
			);
			preferredProjectObjectVersion = 60;
			productRefGroup = AA0000000000000000000042 /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				AA0000000000000000000050 /* LimitBar */,
			);
		};
/* End PBXProject section */

/* Begin PBXSourcesBuildPhase section */
		AA0000000000000000000032 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				AA0000000000000000000001 /* LimitBarApp.swift in Sources */,
				AA0000000000000000000002 /* MonitoringPopoverView.swift in Sources */,
				AA0000000000000000000003 /* LimitBarSettingsView.swift in Sources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		AA0000000000000000000081 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CLANG_ANALYZER_NONNULL = YES;
				CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;
				CLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				CLANG_ENABLE_OBJC_WEAK = YES;
				CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;
				CLANG_WARN_BOOL_CONVERSION = YES;
				CLANG_WARN_COMMA = YES;
				CLANG_WARN_CONSTANT_CONVERSION = YES;
				CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;
				CLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;
				CLANG_WARN_DOCUMENTATION_COMMENTS = YES;
				CLANG_WARN_EMPTY_BODY = YES;
				CLANG_WARN_ENUM_CONVERSION = YES;
				CLANG_WARN_INFINITE_RECURSION = YES;
				CLANG_WARN_INT_CONVERSION = YES;
				CLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;
				CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;
				CLANG_WARN_OBJC_LITERAL_CONVERSION = YES;
				CLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;
				CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;
				CLANG_WARN_RANGE_LOOP_ANALYSIS = YES;
				CLANG_WARN_STRICT_PROTOTYPES = YES;
				CLANG_WARN_SUSPICIOUS_MOVE = YES;
				CLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;
				CLANG_WARN_UNREACHABLE_CODE = YES;
				CLANG_WARN__DUPLICATE_METHOD_MATCH = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_TESTABILITY = YES;
				ENABLE_USER_SCRIPT_SANDBOXING = YES;
				GCC_C_LANGUAGE_STANDARD = gnu17;
				GCC_DYNAMIC_NO_PIC = NO;
				GCC_NO_COMMON_BLOCKS = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"DEBUG=1",
					"$(inherited)",
				);
				GCC_WARN_64_TO_32_BIT_CONVERSION = YES;
				GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
				GCC_WARN_UNDECLARED_SELECTOR = YES;
				GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
				GCC_WARN_UNUSED_FUNCTION = YES;
				GCC_WARN_UNUSED_VARIABLE = YES;
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
				MTL_FAST_MATH = YES;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = macosx;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
			};
			name = Debug;
		};
		AA0000000000000000000082 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CLANG_ANALYZER_NONNULL = YES;
				CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;
				CLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				CLANG_ENABLE_OBJC_WEAK = YES;
				CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;
				CLANG_WARN_BOOL_CONVERSION = YES;
				CLANG_WARN_COMMA = YES;
				CLANG_WARN_CONSTANT_CONVERSION = YES;
				CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;
				CLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;
				CLANG_WARN_DOCUMENTATION_COMMENTS = YES;
				CLANG_WARN_EMPTY_BODY = YES;
				CLANG_WARN_ENUM_CONVERSION = YES;
				CLANG_WARN_INFINITE_RECURSION = YES;
				CLANG_WARN_INT_CONVERSION = YES;
				CLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;
				CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;
				CLANG_WARN_OBJC_LITERAL_CONVERSION = YES;
				CLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;
				CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;
				CLANG_WARN_RANGE_LOOP_ANALYSIS = YES;
				CLANG_WARN_STRICT_PROTOTYPES = YES;
				CLANG_WARN_SUSPICIOUS_MOVE = YES;
				CLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;
				CLANG_WARN_UNREACHABLE_CODE = YES;
				CLANG_WARN__DUPLICATE_METHOD_MATCH = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				ENABLE_NS_ASSERTIONS = NO;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_USER_SCRIPT_SANDBOXING = YES;
				GCC_C_LANGUAGE_STANDARD = gnu17;
				GCC_NO_COMMON_BLOCKS = YES;
				GCC_WARN_64_TO_32_BIT_CONVERSION = YES;
				GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
				GCC_WARN_UNDECLARED_SELECTOR = YES;
				GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
				GCC_WARN_UNUSED_FUNCTION = YES;
				GCC_WARN_UNUSED_VARIABLE = YES;
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				MTL_ENABLE_DEBUG_INFO = NO;
				MTL_FAST_MATH = YES;
				SDKROOT = macosx;
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_OPTIMIZATION_LEVEL = "-O";
			};
			name = Release;
		};
		AA0000000000000000000091 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				CODE_SIGN_STYLE = Automatic;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_HARDENED_RUNTIME = YES;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_CFBundleDisplayName = LimitBar;
				INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.productivity";
				INFOPLIST_KEY_LSUIElement = YES;
				INFOPLIST_KEY_NSHumanReadableCopyright = "";
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				MARKETING_VERSION = 0.1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.talibilat.LimitBar;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
			};
			name = Debug;
		};
		AA0000000000000000000092 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				CODE_SIGN_STYLE = Automatic;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_HARDENED_RUNTIME = YES;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_CFBundleDisplayName = LimitBar;
				INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.productivity";
				INFOPLIST_KEY_LSUIElement = YES;
				INFOPLIST_KEY_NSHumanReadableCopyright = "";
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				MARKETING_VERSION = 0.1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.talibilat.LimitBar;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
			};
			name = Release;
		};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		AA0000000000000000000080 /* Build configuration list for PBXProject "LimitBar" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				AA0000000000000000000081 /* Debug */,
				AA0000000000000000000082 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
		AA0000000000000000000090 /* Build configuration list for PBXNativeTarget "LimitBar" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				AA0000000000000000000091 /* Debug */,
				AA0000000000000000000092 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
/* End XCConfigurationList section */

/* Begin XCLocalSwiftPackageReference section */
		AA0000000000000000000060 /* XCLocalSwiftPackageReference "LimitBarCore" */ = {
			isa = XCLocalSwiftPackageReference;
			relativePath = LimitBarCore;
		};
/* End XCLocalSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
		AA0000000000000000000061 /* LimitBarCore */ = {
			isa = XCSwiftPackageProductDependency;
			productName = LimitBarCore;
		};
/* End XCSwiftPackageProductDependency section */
	};
	rootObject = AA0000000000000000000070 /* Project object */;
}
```

- [ ] **Step 6: Add the shared Xcode scheme**

Create `LimitBar.xcodeproj/xcshareddata/xcschemes/LimitBar.xcscheme`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES"
      buildArchitectures = "Automatic">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "AA0000000000000000000050"
               BuildableName = "LimitBar.app"
               BlueprintName = "LimitBar"
               ReferencedContainer = "container:LimitBar.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "AA0000000000000000000050"
            BuildableName = "LimitBar.app"
            BlueprintName = "LimitBar"
            ReferencedContainer = "container:LimitBar.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "AA0000000000000000000050"
            BuildableName = "LimitBar.app"
            BlueprintName = "LimitBar"
            ReferencedContainer = "container:LimitBar.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
```

- [ ] **Step 7: Verify the project file parses**

Run: `plutil -lint LimitBar.xcodeproj/project.pbxproj`

Expected: `LimitBar.xcodeproj/project.pbxproj: OK`.

- [ ] **Step 8: Verify the scheme file parses**

Run: `xmllint --noout LimitBar.xcodeproj/xcshareddata/xcschemes/LimitBar.xcscheme`

Expected: no output and exit code 0.

- [ ] **Step 9: Verify the native app target when full Xcode is available**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" xcodebuild -project LimitBar.xcodeproj -scheme LimitBar -destination 'platform=macOS' build`

Expected with full Xcode selected: BUILD SUCCEEDED.

Expected in the current Command Line Tools-only environment: `xcode-select: error: tool 'xcodebuild' requires Xcode`.

---

### Task 3: README Build And Test Documentation

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: file layout and commands from Tasks 1 and 2.
- Produces: local setup commands required by issue #1.

- [ ] **Step 1: Write README documentation**

Create `README.md`:

```markdown
# LimitBar

LimitBar is a private macOS 14+ menu bar utility for monitoring AI provider usage.

## Project Layout

- `LimitBar.xcodeproj` contains the native macOS SwiftUI app target.
- `LimitBar` contains the menu bar app shell, monitoring popover, and settings shell.
- `LimitBarCore` contains testable core code that does not depend on SwiftUI.

## Requirements

- macOS 14 or newer.
- Full Xcode for native app builds with `xcodebuild`.
- Swift 6 command line tools for core package tests.

## Test Core Package

```sh
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore
```

## Build Native App

```sh
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" xcodebuild -project LimitBar.xcodeproj -scheme LimitBar -destination 'platform=macOS' build
```

## Run The App

Open `LimitBar.xcodeproj` in Xcode and run the `LimitBar` scheme.
The app appears as a compact menu bar item and opens the monitoring popover from the menu bar.

## Issue #1 Scope

This bootstrap does not add provider integrations, persistence, credentials, notifications, sounds, or urgent alerts.
```

- [ ] **Step 2: Verify core test command from README**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore`

Expected: PASS with 1 test and 0 failures.

- [ ] **Step 3: Verify native build command behavior**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" xcodebuild -project LimitBar.xcodeproj -scheme LimitBar -destination 'platform=macOS' build`

Expected with full Xcode selected: BUILD SUCCEEDED.

Expected in the current Command Line Tools-only environment: `xcode-select: error: tool 'xcodebuild' requires Xcode`.

---

## Final Verification

- Run `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore` and require passing output.
- Run `plutil -lint LimitBar.xcodeproj/project.pbxproj` and require `OK` output.
- Run `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" xcodebuild -project LimitBar.xcodeproj -scheme LimitBar -destination 'platform=macOS' build` if full Xcode is installed.
- Run `git status --short` and review all changed files before committing.
- Run the code review workflow against `main` before pushing.
- Run `no-mistakes axi` and then `no-mistakes axi run --intent "Bootstrap LimitBar issue #1 as a native macOS 14+ menu bar app shell with a separate testable core package, README commands, no provider integrations, no persistence, no credentials, no notifications, no sounds, and no urgent alerts."` before pushing if the repo is initialized for no-mistakes.

## Self-Review

- Spec coverage: Task 1 covers the separate testable core package, Task 2 covers the native app target, menu bar item, popover, settings scene, and no alert APIs, and Task 3 covers local setup commands.
- Placeholder scan: no unfinished markers, vague implementation steps, or unspecified tests remain.
- Type consistency: `AppStatus.initial`, `menuBarText`, `symbolName`, and `accessibilityDescription` match across tests and app code.
