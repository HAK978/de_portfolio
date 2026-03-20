/// Represents a CS2 inventory item.
///
/// In Phase 1 we use mock data; later phases will populate this
/// from Steam API responses and Firestore documents.
class CS2Item {
  final String id;
  final String name;
  final String weaponType; // "Rifle", "Pistol", "Knife", "Gloves", etc.
  final String skinName; // "Redline", "Asiimov", etc.
  final String? wear; // "Factory New", "Minimal Wear", etc. (null for non-skin items)
  final String rarity;
  final String rarityColor; // hex color string
  final bool isStatTrak;
  final bool isSouvenir;
  final double currentPrice; // Steam Community Market price
  final double? csfloatPrice; // CSFloat lowest listing price
  final double priceChange24h; // percentage
  final double priceChange7d;
  final double priceChange30d;
  final int quantity;
  final String location; // "inventory", "Storage Unit 1", etc.
  final String imageUrl;
  final String marketHashName; // Steam market identifier

  const CS2Item({
    required this.id,
    required this.name,
    required this.weaponType,
    required this.skinName,
    required this.wear,
    required this.rarity,
    required this.rarityColor,
    this.isStatTrak = false,
    this.isSouvenir = false,
    required this.currentPrice,
    this.csfloatPrice,
    this.priceChange24h = 0,
    this.priceChange7d = 0,
    this.priceChange30d = 0,
    this.quantity = 1,
    this.location = 'inventory',
    required this.imageUrl,
    required this.marketHashName,
  });

  /// Creates a copy of this item with the given fields replaced.
  ///
  /// This is the standard Dart pattern for updating immutable objects.
  /// Since all fields are `final`, we can't modify them — instead we
  /// create a new CS2Item with the changed values and keep the rest.
  CS2Item copyWith({
    String? id,
    String? name,
    String? weaponType,
    String? skinName,
    String? wear,
    String? rarity,
    String? rarityColor,
    bool? isStatTrak,
    bool? isSouvenir,
    double? currentPrice,
    double? csfloatPrice,
    double? priceChange24h,
    double? priceChange7d,
    double? priceChange30d,
    int? quantity,
    String? location,
    String? imageUrl,
    String? marketHashName,
  }) {
    return CS2Item(
      id: id ?? this.id,
      name: name ?? this.name,
      weaponType: weaponType ?? this.weaponType,
      skinName: skinName ?? this.skinName,
      wear: wear ?? this.wear,
      rarity: rarity ?? this.rarity,
      rarityColor: rarityColor ?? this.rarityColor,
      isStatTrak: isStatTrak ?? this.isStatTrak,
      isSouvenir: isSouvenir ?? this.isSouvenir,
      currentPrice: currentPrice ?? this.currentPrice,
      csfloatPrice: csfloatPrice ?? this.csfloatPrice,
      priceChange24h: priceChange24h ?? this.priceChange24h,
      priceChange7d: priceChange7d ?? this.priceChange7d,
      priceChange30d: priceChange30d ?? this.priceChange30d,
      quantity: quantity ?? this.quantity,
      location: location ?? this.location,
      imageUrl: imageUrl ?? this.imageUrl,
      marketHashName: marketHashName ?? this.marketHashName,
    );
  }

  /// Converts this item to a JSON-compatible map for disk caching.
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'weaponType': weaponType,
    'skinName': skinName,
    'wear': wear,
    'rarity': rarity,
    'rarityColor': rarityColor,
    'isStatTrak': isStatTrak,
    'isSouvenir': isSouvenir,
    'currentPrice': currentPrice,
    'csfloatPrice': csfloatPrice,
    'priceChange24h': priceChange24h,
    'priceChange7d': priceChange7d,
    'priceChange30d': priceChange30d,
    'quantity': quantity,
    'location': location,
    'imageUrl': imageUrl,
    'marketHashName': marketHashName,
  };

  /// Creates a CS2Item from a JSON map (loaded from cache).
  factory CS2Item.fromJson(Map<String, dynamic> json) => CS2Item(
    id: json['id'] as String,
    name: json['name'] as String,
    weaponType: json['weaponType'] as String,
    skinName: json['skinName'] as String,
    wear: json['wear'] as String?,
    rarity: json['rarity'] as String,
    rarityColor: json['rarityColor'] as String,
    isStatTrak: json['isStatTrak'] as bool? ?? false,
    isSouvenir: json['isSouvenir'] as bool? ?? false,
    currentPrice: (json['currentPrice'] as num).toDouble(),
    csfloatPrice: (json['csfloatPrice'] as num?)?.toDouble(),
    priceChange24h: (json['priceChange24h'] as num?)?.toDouble() ?? 0,
    priceChange7d: (json['priceChange7d'] as num?)?.toDouble() ?? 0,
    priceChange30d: (json['priceChange30d'] as num?)?.toDouble() ?? 0,
    quantity: json['quantity'] as int? ?? 1,
    location: json['location'] as String? ?? 'inventory',
    imageUrl: json['imageUrl'] as String,
    marketHashName: json['marketHashName'] as String,
  );

  /// Full display name including StatTrak/Souvenir prefix and wear.
  String get displayName {
    final prefix =
        isStatTrak
            ? 'StatTrak\u2122 '
            : isSouvenir
            ? 'Souvenir '
            : '';
    final wearSuffix = wear != null ? ' ($wear)' : '';
    return '$prefix$name$wearSuffix';
  }
}
