/// One known cache directory, with the name and ecosystem the screen shows.
class CacheLocation {
  const CacheLocation({
    required this.path,
    required this.label,
    required this.ecosystem,
  });

  final String path;
  final String label;
  final String ecosystem;
}

/// The caches this machine's tools write and can regenerate.
///
/// The list is a deliberate allowlist. It holds only directories whose loss
/// costs a rebuild or a re-download — never an archive, a simulator device, an
/// SDK or anything the user authored. A scan never walks the whole disk looking
/// for "caches"; it reads these paths and nothing else.
List<CacheLocation> macCacheLocations({required String home}) => [
  CacheLocation(
    path: '$home/Library/Developer/Xcode/DerivedData',
    label: 'Xcode DerivedData',
    ecosystem: 'Xcode',
  ),
  CacheLocation(
    path: '$home/Library/Developer/Xcode/iOS DeviceSupport',
    label: 'iOS DeviceSupport',
    ecosystem: 'Xcode',
  ),
  CacheLocation(
    path: '$home/Library/Developer/Xcode/watchOS DeviceSupport',
    label: 'watchOS DeviceSupport',
    ecosystem: 'Xcode',
  ),
  CacheLocation(
    path: '$home/Library/Developer/Xcode/tvOS DeviceSupport',
    label: 'tvOS DeviceSupport',
    ecosystem: 'Xcode',
  ),
  CacheLocation(
    path: '$home/Library/Developer/CoreSimulator/Caches',
    label: 'Simulator caches',
    ecosystem: 'Simulator',
  ),
  CacheLocation(
    path: '$home/Library/Caches/CocoaPods',
    label: 'CocoaPods cache',
    ecosystem: 'CocoaPods',
  ),
  CacheLocation(
    path: '$home/Library/Caches/Homebrew',
    label: 'Homebrew cache',
    ecosystem: 'Homebrew',
  ),
  CacheLocation(
    path: '$home/.gradle/caches',
    label: 'Gradle caches',
    ecosystem: 'Gradle',
  ),
  CacheLocation(
    path: '$home/.npm/_cacache',
    label: 'npm cache',
    ecosystem: 'Node',
  ),
  CacheLocation(
    path: '$home/Library/Caches/Yarn',
    label: 'Yarn cache',
    ecosystem: 'Node',
  ),
  CacheLocation(
    path: '$home/Library/pnpm/store',
    label: 'pnpm store',
    ecosystem: 'Node',
  ),
  CacheLocation(
    path: '$home/.pub-cache',
    label: 'Pub cache',
    ecosystem: 'Dart',
  ),
  CacheLocation(
    path: '$home/Library/Caches/go-build',
    label: 'Go build cache',
    ecosystem: 'Go',
  ),
  CacheLocation(
    path: '$home/.cargo/registry/cache',
    label: 'Cargo registry cache',
    ecosystem: 'Rust',
  ),
];

List<CacheLocation> linuxCacheLocations({
  required String home,
  Map<String, String> environment = const <String, String>{},
}) {
  final dataHome = environment['XDG_DATA_HOME'] ?? '$home/.local/share';
  final cacheHome = environment['XDG_CACHE_HOME'] ?? '$home/.cache';
  return [
    CacheLocation(
      path: '$home/.gradle/caches',
      label: 'Gradle caches',
      ecosystem: 'Gradle',
    ),
    CacheLocation(
      path: '$home/.npm/_cacache',
      label: 'npm cache',
      ecosystem: 'Node',
    ),
    CacheLocation(
      path: '$cacheHome/yarn',
      label: 'Yarn cache',
      ecosystem: 'Node',
    ),
    CacheLocation(
      path: '$dataHome/pnpm/store',
      label: 'pnpm store',
      ecosystem: 'Node',
    ),
    CacheLocation(
      path: '$home/.pub-cache',
      label: 'Pub cache',
      ecosystem: 'Dart',
    ),
    CacheLocation(
      path: '$cacheHome/go-build',
      label: 'Go build cache',
      ecosystem: 'Go',
    ),
    CacheLocation(
      path: '$home/.cargo/registry/cache',
      label: 'Cargo registry cache',
      ecosystem: 'Rust',
    ),
    CacheLocation(
      path: '$cacheHome/Homebrew',
      label: 'Homebrew cache',
      ecosystem: 'Homebrew',
    ),
  ];
}

List<CacheLocation> windowsCacheLocations({
  required String home,
  Map<String, String> environment = const <String, String>{},
}) {
  final local = environment['LOCALAPPDATA'] ?? '$home\\AppData\\Local';
  return [
    CacheLocation(
      path: '$home\\.gradle\\caches',
      label: 'Gradle caches',
      ecosystem: 'Gradle',
    ),
    CacheLocation(
      path: '$local\\npm-cache\\_cacache',
      label: 'npm cache',
      ecosystem: 'Node',
    ),
    CacheLocation(
      path: '$local\\Yarn\\Cache',
      label: 'Yarn cache',
      ecosystem: 'Node',
    ),
    CacheLocation(
      path: '$local\\pnpm\\store',
      label: 'pnpm store',
      ecosystem: 'Node',
    ),
    CacheLocation(
      path: '$local\\Pub\\Cache',
      label: 'Pub cache',
      ecosystem: 'Dart',
    ),
    CacheLocation(
      path: '$local\\go-build',
      label: 'Go build cache',
      ecosystem: 'Go',
    ),
    CacheLocation(
      path: '$home\\.cargo\\registry\\cache',
      label: 'Cargo registry cache',
      ecosystem: 'Rust',
    ),
    CacheLocation(
      path: '$home\\.nuget\\packages',
      label: 'NuGet packages',
      ecosystem: 'NuGet',
    ),
    CacheLocation(
      path: '$local\\NuGet\\v3-cache',
      label: 'NuGet v3 cache',
      ecosystem: 'NuGet',
    ),
  ];
}

/// Where to look for project-local `node_modules`.
///
/// None of these are created or required; a scan simply skips the ones that are
/// not there. They are the conventional checkout folders, not the home
/// directory itself, which keeps the walk bounded and out of `Library`,
/// `.Trash` and other places a project would never live.
List<String> unixProjectRoots(String home) => [
  '$home/Project',
  '$home/Projects',
  '$home/Developer',
  '$home/Code',
  '$home/code',
  '$home/src',
  '$home/workspace',
  '$home/GitHub',
  '$home/git',
  '$home/repos',
  '$home/WebstormProjects',
  '$home/IdeaProjects',
];

List<String> windowsProjectRoots(String home) => [
  '$home\\Project',
  '$home\\Projects',
  '$home\\Developer',
  '$home\\source\\repos',
  '$home\\repos',
  '$home\\Documents\\GitHub',
];
