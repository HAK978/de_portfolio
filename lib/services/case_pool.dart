// Active-drop classification for CS2 containers.
//
// Valve rotates the container drop pool roughly every few months.
// Until a CSFloat-style scraped feed is wired up, this list is
// hand-maintained — bump it when a new container is released or
// Valve announces a rotation change.
//
// Notes for future maintenance:
// - As of Dec 2025, Valve removed the legacy "rare drop" pool, so
//   classification is binary: activeDrop vs discontinued. Anything
//   not in [_activeDropContainers] is treated as discontinued.
// - "Terminal" containers (introduced 2026) classify the same way
//   as classic " Case" weapon containers — they all drop end-of-match.
// - Capsules, packages, charm boxes, etc. don't participate in the
//   weekly drop pool concept and return [CaseDropStatus.notApplicable].

/// Drop-pool status for a container item.
enum CaseDropStatus {
  /// Currently drops at end-of-match in CS2. Supply is steady.
  activeDrop,

  /// Used to drop, no longer does. Supply only decreases as keys are
  /// opened — prices typically rise over time.
  discontinued,

  /// Container that isn't a weapon-style drop case (sticker capsule,
  /// souvenir package, charm capsule, etc.) where the drop-pool
  /// concept doesn't apply.
  notApplicable,
}

/// Hand-maintained list of containers currently in the active drop
/// pool. Update when Valve rotates the pool (~3-4 times a year).
///
/// **Last verified: 2026-05-05.** Verify against the latest
/// announcement before relying on this for resale decisions:
/// https://blog.counter-strike.net/
const Set<String> _activeDropContainers = {
  // Confirmed against Steam Market hash names — keep these exact.
  'Kilowatt Case',
  'Revolution Case',
  'Dreams & Nightmares Case',
  // Newer "Terminal" containers introduced in early 2026. The exact
  // market_hash_name spelling may differ from these guesses — verify
  // by searching Steam Market and edit if a chip shows wrong status.
  'Genesis Terminal',
  'Dead Hand Terminal',
  'Sealed Dead Hand Terminal',
};

/// True if [name] matches the weapon-case naming convention. Used to
/// distinguish drop-pool containers from capsules / souvenir packages
/// / charm boxes etc.
bool _isWeaponCaseLike(String name) {
  return name.endsWith(' Case') || name.endsWith(' Terminal');
}

/// Classify a container by its market_hash_name and (optional)
/// weaponType. Pass weaponType when available — short-circuits the
/// name check for items that aren't containers at all.
CaseDropStatus classifyContainer({
  required String marketHashName,
  String? weaponType,
}) {
  if (weaponType != null && weaponType != 'Container') {
    return CaseDropStatus.notApplicable;
  }
  if (!_isWeaponCaseLike(marketHashName)) {
    return CaseDropStatus.notApplicable;
  }
  if (_activeDropContainers.contains(marketHashName)) {
    return CaseDropStatus.activeDrop;
  }
  return CaseDropStatus.discontinued;
}
