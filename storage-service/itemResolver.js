/**
 * Item name/image resolver — adapted from CaseMove's items/index.js
 *
 * Resolves raw GC item data (def_index, paint_index, etc.) into
 * human-readable names and image URLs.
 *
 * On startup, downloads fresh item definitions from skinledger.com.
 * Falls back to bundled backup files if the download fails.
 */

const VDF = require('@node-steam/vdf');
const axios = require('axios');
const path = require('path');

const ITEMS_URL = 'https://files.skinledger.com/counterstrike/items_game.txt';
const TRANSLATIONS_URL = 'https://files.skinledger.com/counterstrike/csgo_english.txt';
const IMAGE_BASE = 'https://community.cloudflare.steamstatic.com/economy/image/';

class ItemResolver {
  constructor() {
    this.translation = {};
    this.csgoItems = {};
    this.ready = false;
  }

  /** Initialize — download fresh data, fall back to backups */
  async init() {
    // Load backups first (instant)
    try {
      this.translation = require('./itemData/csgo_english.json');
      this.csgoItems = require('./itemData/items_game.json');
      console.log('[Items] Loaded backup item data');
    } catch (e) {
      console.error('[Items] Failed to load backup data:', e.message);
    }

    // Try to download fresh data
    try {
      await this._downloadTranslations();
      await this._downloadItems();
      console.log('[Items] Downloaded fresh item data');
    } catch (e) {
      console.log('[Items] Using backup data (download failed):', e.message);
    }

    this.ready = true;
  }

  async _downloadTranslations() {
    const response = await axios.get(TRANSLATIONS_URL, { timeout: 10000 });
    const finalDict = {};
    const lines = response.data.split(/\n/);
    for (const line of lines) {
      const match = line.match(/"(.*?)"/g);
      if (match && match[1]) {
        finalDict[match[0].replaceAll('"', '').toLowerCase()] = match[1];
      }
    }
    // Validate
    if (Object.keys(finalDict).length < 100) throw new Error('Translation data too small');
    this.translation = finalDict;
  }

  async _downloadItems() {
    const response = await axios.get(ITEMS_URL, { timeout: 10000 });
    const jsonData = VDF.parse(response.data);

    const result = {
      items: {},
      paint_kits: {},
      prefabs: {},
      sticker_kits: {},
      music_kits: {},
      graffiti_tints: {},
      casket_icons: {},
    };

    const extract = (key) => {
      if (jsonData['items_game']?.[key]) {
        for (const [k, v] of Object.entries(jsonData['items_game'][key])) {
          result[key === 'music_definitions' ? 'music_kits' : key][k] = v;
        }
      }
    };

    extract('items');
    extract('paint_kits');
    extract('prefabs');
    extract('sticker_kits');
    extract('music_definitions');
    extract('graffiti_tints');

    if (jsonData['items_game']?.['alternate_icons2']?.['casket_icons']) {
      result['casket_icons'] = jsonData['items_game']['alternate_icons2']['casket_icons'];
    }

    // Validate
    if (!result.items[1209]) throw new Error('Items data missing key entries');
    this.csgoItems = result;
  }

  /** Convert raw GC storage items to readable format */
  convertStorageItems(rawItems) {
    if (!this.ready) return [];

    const results = [];
    for (const item of rawItems) {
      try {
        const converted = this._convertItem(item);
        if (converted) results.push(converted);
      } catch (e) {
        // Skip items that fail to convert
        console.log(`[Items] Failed to convert item ${item.id}: ${e.message}`);
      }
    }
    return results;
  }

  _convertItem(item) {
    if (!item.def_index) return null;

    const defData = this.csgoItems.items?.[item.def_index];
    if (!defData) return null;

    // Get image URL
    let imageUrl = this._getImageUrl(item, defData);

    // Get item name
    let name = this._getItemName(item, defData, imageUrl);
    if (!name) return null;

    // Get wear name
    let wear = null;
    if (item.paint_wear !== undefined) {
      wear = this._getWearName(item.paint_wear);
    }

    // Check StatTrak
    let isStatTrak = false;
    if (item.attribute) {
      for (const attr of item.attribute) {
        if (attr.def_index === 80) {
          isStatTrak = true;
          break;
        }
      }
    }

    // Check Souvenir
    let isSouvenir = false;
    if (item.attribute) {
      for (const attr of item.attribute) {
        if (attr.def_index === 140) {
          isSouvenir = true;
          break;
        }
      }
    }

    // Prefix name
    if (item.quality === 3) {
      name = '★ ' + name;
    }
    if (isStatTrak) {
      name = 'StatTrak™ ' + name;
    }
    if (isSouvenir && !name.includes('Souvenir')) {
      name = 'Souvenir ' + name;
    }

    // Build market_hash_name (name + wear)
    const marketHashName = wear ? `${name} (${wear})` : name;

    // Rarity mapping
    const rarityNames = {
      1: 'Consumer Grade',
      2: 'Industrial Grade',
      3: 'Mil-Spec',
      4: 'Restricted',
      5: 'Classified',
      6: 'Covert',
      7: 'Extraordinary',
    };

    const rarityColors = {
      1: '#b0c3d9',
      2: '#5e98d9',
      3: '#4b69ff',
      4: '#8847ff',
      5: '#d32ce6',
      6: '#eb4b4b',
      7: '#ffd700',
    };

    // Full image URL
    const fullImageUrl = imageUrl
      ? `${IMAGE_BASE}${imageUrl}`
      : '';

    return {
      id: item.id,
      name: name,
      marketHashName: marketHashName,
      wear: wear,
      rarity: rarityNames[item.rarity] || 'Unknown',
      rarityColor: rarityColors[item.rarity] || '#b0c3d9',
      isStatTrak: isStatTrak,
      isSouvenir: isSouvenir,
      imageUrl: fullImageUrl,
      paintWear: item.paint_wear || null,
      defIndex: item.def_index,
      paintIndex: item.paint_index || null,
      tradableAfter: item.tradable_after || null,
    };
  }

  _getItemName(item, defData, imageUrl) {
    // CS:GO Case Key special case
    if (imageUrl === 'econ/tools/weapon_case_key') {
      return 'CS:GO Case Key';
    }

    // Music kit
    if (item.music_index !== undefined) {
      const musicData = this.csgoItems.music_kits?.[item.music_index];
      if (musicData?.loc_name) {
        return 'Music Kit | ' + this._translate(musicData.loc_name);
      }
    }

    // Base item name
    let baseName = null;
    if (defData.item_name) {
      baseName = this._translate(defData.item_name);
    } else if (defData.prefab) {
      const prefab = this.csgoItems.prefabs?.[defData.prefab];
      if (prefab?.item_name) {
        baseName = this._translate(prefab.item_name);
      }
    }
    if (!baseName) return null;

    // Skin name (from paint_index)
    let skinName = null;
    if (item.paint_index !== undefined) {
      const paintData = this.csgoItems.paint_kits?.[item.paint_index];
      if (paintData?.description_tag) {
        skinName = this._translate(paintData.description_tag);
      }
    } else if (item.stickers?.length > 0 && !imageUrl?.includes('econ/characters/')) {
      // Sticker/patch name
      const sticker = item.stickers[0];
      if (sticker.slot === 0 && !baseName.includes('Coin')) {
        const stickerData = this.csgoItems.sticker_kits?.[sticker.sticker_id];
        if (stickerData?.item_name) {
          skinName = this._translate(stickerData.item_name);
        }
      }
    }

    let finalName = skinName ? `${baseName} | ${skinName}` : baseName;

    // Graffiti tint
    if (item.graffiti_tint !== undefined) {
      const tintName = this._getGraffitiTintName(item.graffiti_tint);
      if (tintName) {
        finalName += ` (${tintName})`;
      }
    }

    return finalName;
  }

  _getImageUrl(item, defData) {
    // Music kit
    if (item.music_index !== undefined) {
      const musicData = this.csgoItems.music_kits?.[item.music_index];
      return musicData?.image_inventory || null;
    }

    // Item with paint (weapon skin)
    if (item.paint_index !== undefined) {
      const paintData = this.csgoItems.paint_kits?.[item.paint_index];
      if (paintData) {
        return `econ/default_generated/${defData.name}_${paintData.name}_light_large`;
      }
    }

    // Base weapon
    if (defData.baseitem == 1) {
      return `econ/weapons/base_weapons/${defData.name}`;
    }

    // Sticker/patch
    if (item.stickers?.length > 0 && !defData.image_inventory) {
      const sticker = item.stickers[0];
      const stickerData = this.csgoItems.sticker_kits?.[sticker.sticker_id];
      if (stickerData?.patch_material) {
        return `econ/patches/${stickerData.patch_material}`;
      } else if (stickerData?.sticker_material) {
        return `econ/stickers/${stickerData.sticker_material}`;
      }
    }

    return defData.image_inventory || null;
  }

  _getWearName(paintWear) {
    const thresholds = [0.07, 0.15, 0.38, 0.45, 1];
    const names = ['Factory New', 'Minimal Wear', 'Field-Tested', 'Well-Worn', 'Battle-Scarred'];
    for (let i = 0; i < thresholds.length; i++) {
      if (paintWear <= thresholds[i]) return names[i];
    }
    return 'Battle-Scarred';
  }

  _translate(csgoString) {
    if (!csgoString) return null;
    const key = csgoString.replace('#', '').toLowerCase();
    const value = this.translation[key];
    return value ? value.replaceAll('"', '') : csgoString;
  }

  _getGraffitiTintName(tintId) {
    for (const [key, value] of Object.entries(this.csgoItems.graffiti_tints || {})) {
      if (value.id == tintId) {
        return key.replaceAll('_', ' ').replace(/(?:^|\s)\S/g, (a) => a.toUpperCase()).replace('Swat', 'SWAT');
      }
    }
    return null;
  }

  /** Extract music_index from item attributes (stored in attribute 166) */
  _extractMusicIndex(item) {
    if (!item.attribute) return;
    const attr = item.attribute.find((a) => a.def_index === 166);
    if (attr?.value_bytes) {
      item.music_index = attr.value_bytes.readUInt32LE(0);
    }
  }

  /** Extract graffiti_tint from item attributes (stored in attribute 233) */
  _extractGraffitiTint(item) {
    if (!item.attribute) return;
    const attr = item.attribute.find((a) => a.def_index === 233);
    if (attr?.value_bytes) {
      item.graffiti_tint = attr.value_bytes.readUInt32LE(0);
    }
  }
}

module.exports = ItemResolver;
