import '../models/cs2_item.dart';
import '../models/storage_unit.dart';

/// Mock inventory data for Phase 1 UI development.
///
/// These represent realistic CS2 items with actual market hash names,
/// rarity colors, and plausible prices. Images use placeholder URLs
/// since Steam CDN requires real icon_url hashes.
const _steamImageBase =
    'https://community.cloudflare.steamstatic.com/economy/image/';

// Placeholder icon hashes (these are real ones from common items)
const _ak47RedlineIcon =
    '-9a81dlWLwJ2UXp-aHag0uDaHQjPiQKGkpmNTg9bKQGqyYq3m5d7mfz_g0cax0QfZt0EqPcY2o9SThMGYsYbe1v7IYPHXhRlKBsspeuY62pxqScJG0avoji29TdlvD6DLfQklRc7cF4n-T--YXygECA8hFqZjiiI4KSIVQ8M1yG_1i5kLq9h5e_ot2XnA';
const _awpAsiimovIcon =
    '-9a81dlWLwJ2UXp-aHag0uDaHQjPiQKGkpmNTg9bKQGqyYq3m5d7mfz_g0cax0QfZt0EqPcY2o9SThMGYsYbe1v7IYPHhFps7m2xQRXhMPFJ_jxdDkM7OPgZL-JmvbmJ7_Qh2le6cBj3-v89TziQGyr0VtZWj1cNOXJFM6M1CD-gC2x-vmhpDqv5ybnHEz6SAq4XjD30vg5pgJM7c';
const _m4a1HyperBeastIcon =
    '-9a81dlWLwJ2UXp-aHag0uDaHQjPiQKGkpmNTg9bKQGqyYq3m5d7mfz_g0cax0QfZt0EqPcY2o9SThMGYsYbe1v7IYPHhFps7m2xRV30vD3fDhS08uhkIWJkIGKlvjnMbXUmFRc7cF4n-T--YXygECA-UVvZDr1LdSUe1A2YVGD-Fi-xO281JS8u5ucynNhvCMn5XqImkLjmh9SLrs4Z50ShAecdKPNE';

final List<CS2Item> mockItems = [
  CS2Item(
    id: '1',
    name: 'AK-47 | Redline',
    weaponType: 'Rifle',
    skinName: 'Redline',
    wear: 'Field-Tested',
    rarity: 'Classified',
    rarityColor: '#D32CE6',
    currentPrice: 12.50,
    priceChange24h: 5.2,
    priceChange7d: -2.1,
    priceChange30d: 15.8,
    quantity: 50,
    location: 'inventory',
    imageUrl: '$_steamImageBase$_ak47RedlineIcon',
    marketHashName: 'AK-47 | Redline (Field-Tested)',
  ),
  CS2Item(
    id: '2',
    name: 'AWP | Asiimov',
    weaponType: 'Rifle',
    skinName: 'Asiimov',
    wear: 'Field-Tested',
    rarity: 'Covert',
    rarityColor: '#EB4B4B',
    currentPrice: 32.80,
    priceChange24h: -1.5,
    priceChange7d: 8.3,
    priceChange30d: 22.1,
    quantity: 5,
    location: 'inventory',
    imageUrl: '$_steamImageBase$_awpAsiimovIcon',
    marketHashName: 'AWP | Asiimov (Field-Tested)',
  ),
  CS2Item(
    id: '3',
    name: 'M4A1-S | Hyper Beast',
    weaponType: 'Rifle',
    skinName: 'Hyper Beast',
    wear: 'Minimal Wear',
    rarity: 'Covert',
    rarityColor: '#EB4B4B',
    currentPrice: 45.20,
    priceChange24h: 12.8,
    priceChange7d: 25.4,
    priceChange30d: 48.0,
    quantity: 2,
    location: 'inventory',
    imageUrl: '$_steamImageBase$_m4a1HyperBeastIcon',
    marketHashName: 'M4A1-S | Hyper Beast (Minimal Wear)',
  ),
  CS2Item(
    id: '4',
    name: 'USP-S | Kill Confirmed',
    weaponType: 'Pistol',
    skinName: 'Kill Confirmed',
    wear: 'Factory New',
    rarity: 'Covert',
    rarityColor: '#EB4B4B',
    isStatTrak: true,
    currentPrice: 128.50,
    priceChange24h: 3.2,
    priceChange7d: -5.0,
    priceChange30d: 10.5,
    quantity: 1,
    location: 'inventory',
    imageUrl: '$_steamImageBase$_ak47RedlineIcon', // placeholder
    marketHashName: 'StatTrak\u2122 USP-S | Kill Confirmed (Factory New)',
  ),
  CS2Item(
    id: '5',
    name: 'Glock-18 | Fade',
    weaponType: 'Pistol',
    skinName: 'Fade',
    wear: 'Factory New',
    rarity: 'Restricted',
    rarityColor: '#8847FF',
    currentPrice: 850.00,
    priceChange24h: -0.3,
    priceChange7d: 2.1,
    priceChange30d: -8.5,
    quantity: 1,
    location: 'inventory',
    imageUrl: '$_steamImageBase$_ak47RedlineIcon', // placeholder
    marketHashName: 'Glock-18 | Fade (Factory New)',
  ),
  CS2Item(
    id: '6',
    name: '\u2605 Butterfly Knife | Doppler',
    weaponType: 'Knife',
    skinName: 'Doppler',
    wear: 'Factory New',
    rarity: 'Extraordinary',
    rarityColor: '#FFD700',
    currentPrice: 1850.00,
    priceChange24h: 1.8,
    priceChange7d: 5.5,
    priceChange30d: 12.0,
    quantity: 1,
    location: 'inventory',
    imageUrl: '$_steamImageBase$_ak47RedlineIcon', // placeholder
    marketHashName: '\u2605 Butterfly Knife | Doppler (Factory New)',
  ),
  CS2Item(
    id: '7',
    name: 'Operation Breakout Weapon Case',
    weaponType: 'Container',
    skinName: '',
    wear: null,
    rarity: 'Industrial Grade',
    rarityColor: '#5E98D9',
    currentPrice: 1.20,
    priceChange24h: 85.0,
    priceChange7d: 120.0,
    priceChange30d: 200.0,
    quantity: 200,
    location: 'Storage Unit 1',
    imageUrl: '$_steamImageBase$_ak47RedlineIcon', // placeholder
    marketHashName: 'Operation Breakout Weapon Case',
  ),
  CS2Item(
    id: '8',
    name: 'Sticker | Katowice 2014 (Holo)',
    weaponType: 'Sticker',
    skinName: '',
    wear: null,
    rarity: 'Extraordinary',
    rarityColor: '#FFD700',
    currentPrice: 5200.00,
    priceChange24h: 0.5,
    priceChange7d: -1.2,
    priceChange30d: 8.0,
    quantity: 1,
    location: 'Storage Unit 2',
    imageUrl: '$_steamImageBase$_ak47RedlineIcon', // placeholder
    marketHashName: 'Sticker | Katowice 2014 (Holo)',
  ),
  CS2Item(
    id: '9',
    name: 'AK-47 | Redline',
    weaponType: 'Rifle',
    skinName: 'Redline',
    wear: 'Field-Tested',
    rarity: 'Classified',
    rarityColor: '#D32CE6',
    currentPrice: 12.50,
    priceChange24h: 5.2,
    priceChange7d: -2.1,
    priceChange30d: 15.8,
    quantity: 100,
    location: 'Storage Unit 1',
    imageUrl: '$_steamImageBase$_ak47RedlineIcon',
    marketHashName: 'AK-47 | Redline (Field-Tested)',
  ),
  CS2Item(
    id: '10',
    name: 'Desert Eagle | Blaze',
    weaponType: 'Pistol',
    skinName: 'Blaze',
    wear: 'Factory New',
    rarity: 'Restricted',
    rarityColor: '#8847FF',
    currentPrice: 320.00,
    priceChange24h: -2.5,
    priceChange7d: 1.0,
    priceChange30d: -5.0,
    quantity: 3,
    location: 'inventory',
    imageUrl: '$_steamImageBase$_ak47RedlineIcon', // placeholder
    marketHashName: 'Desert Eagle | Blaze (Factory New)',
  ),
];

final List<StorageUnit> mockStorageUnits = [
  StorageUnit(
    id: 'su1',
    name: 'Cases & Investments',
    itemCount: 300,
    totalValue: 1490.00,
    items: mockItems.where((i) => i.location == 'Storage Unit 1').toList(),
  ),
  StorageUnit(
    id: 'su2',
    name: 'High-Value Stickers',
    itemCount: 1,
    totalValue: 5200.00,
    items: mockItems.where((i) => i.location == 'Storage Unit 2').toList(),
  ),
];
