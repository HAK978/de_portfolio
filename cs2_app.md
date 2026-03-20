# de_portfolio — CS2 Inventory Manager — Flutter Project Brief

## Project Overview

A Flutter mobile app (Android-first, cross-platform ready) for managing CS2 Steam inventories of any size. Users can have up to 1,000 items in their main inventory and unlimited storage units (each holding up to 1,000 items), so the app needs to handle inventories ranging from a few dozen items to tens of thousands across many containers. The app tracks items, monitors prices, and alerts users when items spike in value so they can sell at the right time.

**Primary Goals:**
1. Learn Flutter/Dart and full-stack development with Firebase
2. Build a genuinely useful tool for CS2 inventory management

**Learning Approach — IMPORTANT:**
- Before writing any code for a new feature, explain the Flutter/Dart concepts involved first
- After writing code, pause and ask if I want anything explained
- When introducing a new widget or pattern, briefly explain WHY it's used over alternatives
- Keep commits/changes small and incremental so I can follow along

---

## Tech Stack

| Layer | Technology | Purpose |
|-------|-----------|---------|
| Frontend | Flutter + Dart | Mobile UI (Android primary) |
| State Management | Riverpod | App state, dependency injection |
| Backend | Firebase (Firestore, Cloud Functions, Auth, FCM) | Database, serverless logic, auth, push notifications |
| APIs | Steam Web API (inventory), Steam Community Market / SteamWebAPI.com (pricing) | Data sources |
| Storage Unit Access | Node.js service using `node-steam-user` + `node-globaloffensive` (Phase 6) | GC communication |

---

## Phased Build Plan

### Phase 1: Flutter UI Shell (Mock Data)
**Goal:** Learn Flutter widgets, navigation, state management fundamentals

**Screens to build:**
1. **Home / Dashboard**
   - Total portfolio value (mocked)
   - Quick stats: total items, items in storage, top gainers/losers
   - Navigation to other screens

2. **Inventory List**
   - Scrollable list of items with image, name, quantity, current price
   - Group duplicate items (e.g., "AK-47 | Redline × 50")
   - Search bar with text filtering
   - Filter chips: by weapon type, rarity, price range
   - Sort options: price (high/low), name, quantity, recent price change %

3. **Item Detail**
   - Item image (large)
   - Name, wear, rarity, type
   - Current price, price change (24h, 7d, 30d)
   - Price history chart (placeholder)
   - Quantity owned
   - Location (inventory vs which storage unit)

4. **Storage Units View**
   - List of storage units with name, item count, total value
   - Tap to expand and see contents

5. **Settings**
   - Steam ID input
   - Notification preferences
   - Currency selection

**Key Flutter concepts to learn in Phase 1:**
- StatelessWidget vs StatefulWidget
- Common widgets: Scaffold, AppBar, ListView, GridView, Card, ListTile
- Navigation: GoRouter or Navigator 2.0
- State management: Riverpod (Provider, StateNotifier, FutureProvider)
- Theming: ThemeData, dark mode
- Responsive layout basics

**Mock data structure:**
```dart
class CS2Item {
  final String id;
  final String name;
  final String weaponType;     // "Rifle", "Pistol", "Knife", "Gloves", etc.
  final String skinName;       // "Redline", "Asiimov", etc.
  final String? wear;          // "Factory New", "Minimal Wear", etc.
  final String rarity;         // "Consumer", "Industrial", ..., "Covert", "Extraordinary"
  final String rarityColor;    // hex color for the rarity
  final bool isStatTrak;
  final bool isSouvenir;
  final double currentPrice;
  final double priceChange24h; // percentage
  final double priceChange7d;
  final double priceChange30d;
  final int quantity;
  final String location;       // "inventory", "Storage Unit 1", "Storage Unit 2"
  final String imageUrl;
  final String marketHashName; // Steam market identifier
}

class StorageUnit {
  final String id;
  final String name;           // user-assigned label
  final int itemCount;
  final double totalValue;
  final List<CS2Item> items;
}
```

**Recommended packages for Phase 1:**
```yaml
dependencies:
  flutter_riverpod: ^2.5.0
  go_router: ^14.0.0
  cached_network_image: ^3.3.0    # for item images
  google_fonts: ^6.0.0
  intl: ^0.19.0                    # number/currency formatting
```

---

### Phase 2: Firebase Setup & Auth
**Goal:** Learn Firebase integration, authentication flow, Firestore basics

**Tasks:**
1. Create Firebase project
2. Add Firebase to Flutter app (FlutterFire CLI)
3. Implement Steam OpenID authentication flow:
   - Flutter opens a WebView to Steam's OpenID login
   - Steam redirects back with SteamID64
   - Cloud Function validates the OpenID response
   - Create/update user document in Firestore
   - Store auth state locally
4. Design Firestore schema (see below)
5. Replace mock data with Firestore reads

**Firestore Schema:**
```
users/
  {steamId}/
    displayName: "PlayerName"
    avatarUrl: "https://..."
    lastSync: Timestamp
    settings/
      currency: "USD"
      notificationPrefs: { priceSpike: true, threshold: 50 }

inventories/
  {steamId}/
    items/
      {itemId}/
        marketHashName: "AK-47 | Redline (Field-Tested)"
        name: "AK-47 | Redline"
        wear: "Field-Tested"
        weaponType: "Rifle"
        rarity: "Classified"
        isStatTrak: false
        quantity: 50
        location: "inventory"  // or "storage_unit_1"
        imageUrl: "https://..."
        lastUpdated: Timestamp

    storageUnits/
      {unitId}/
        name: "Cases & Keys"
        itemCount: 850
        lastSynced: Timestamp

prices/
  {marketHashName}/              // shared collection, not per-user
    currentPrice: 12.50
    price24hAgo: 11.00
    price7dAgo: 10.50
    price30dAgo: 9.00
    priceChange24h: 13.6         // percentage
    lastUpdated: Timestamp
    history/                     // subcollection
      {date}/
        price: 12.50
        volume: 1500

alerts/
  {alertId}/
    steamId: "76561198..."
    marketHashName: "AK-47 | Redline (Field-Tested)"
    triggerType: "spike"         // or "threshold"
    thresholdPercent: 50         // e.g., 50% increase
    triggered: false
    createdAt: Timestamp
```

**Key concepts to learn in Phase 2:**
- Firebase project setup and FlutterFire configuration
- Firestore document/collection model
- Firestore queries, where clauses, ordering
- StreamBuilder for real-time Firestore updates
- Firebase Auth custom token flow
- Security rules basics

**Recommended packages for Phase 2:**
```yaml
dependencies:
  firebase_core: ^3.0.0
  firebase_auth: ^5.0.0
  cloud_firestore: ^5.0.0
  webview_flutter: ^4.0.0       # for Steam OpenID login
```

---

### Phase 3: Steam Inventory API Integration
**Goal:** Learn REST API integration, JSON parsing, async patterns

**Tasks:**
1. Fetch inventory from Steam's public endpoint:
   `GET https://steamcommunity.com/inventory/{steamId}/730/2`
   - Handles pagination (Steam returns max ~75 items per request, use `start_assetid` param)
   - Parse the response: `assets[]` + `descriptions[]` joined by `classid` + `instanceid`
2. Map Steam API response to your CS2Item model
3. Sync fetched data to Firestore
4. Build a "Sync Now" button + pull-to-refresh
5. Handle errors: private inventory, rate limiting (429), network failures
6. Cache item images locally

**Important Steam API details:**
- Inventory must be set to public
- Rate limited: ~1 request per second, will return 429 if too fast
- Response has two arrays: `assets` (what you own) and `descriptions` (item metadata)
- Join them on `classid` + `instanceid`
- `market_hash_name` is the unique identifier for pricing
- Images: `https://community.cloudflare.steamstatic.com/economy/image/{icon_url}`

**Key concepts to learn in Phase 3:**
- HTTP requests with `http` or `dio` package
- JSON serialization/deserialization (json_serializable + build_runner)
- Async/await patterns in Dart
- Error handling and retry logic
- Pagination patterns
- Pull-to-refresh (RefreshIndicator)

**Recommended packages for Phase 3:**
```yaml
dependencies:
  dio: ^5.4.0                    # HTTP client with interceptors
  json_annotation: ^4.9.0
dev_dependencies:
  json_serializable: ^6.8.0
  build_runner: ^2.4.0
```

---

### Phase 4: Pricing & Charts
**Goal:** Learn charting, background data fetching, data aggregation

**Tasks:**
1. Integrate pricing API (options):
   - Free: Steam Community Market endpoint (rate limited, basic)
     `GET https://steamcommunity.com/market/priceoverview/?appid=730&market_hash_name={name}&currency=1`
   - Paid: SteamWebAPI.com (reliable, price history, multi-marketplace)
2. Fetch prices for all unique items in inventory
3. Calculate portfolio total value
4. Build price history charts for individual items
5. Show price change indicators (green up, red down)
6. Portfolio value over time chart on dashboard

**Key concepts to learn in Phase 4:**
- Charting libraries (fl_chart or syncfusion_flutter_charts)
- Data aggregation and transformation
- Batch API calls with rate limiting
- Number formatting and currency display

**Recommended packages:**
```yaml
dependencies:
  fl_chart: ^0.68.0              # charts
```

---

### Phase 5: Price Spike Alerts & Notifications
**Goal:** Learn Cloud Functions, push notifications, background processing

**Tasks:**
1. Write a Cloud Function (Node.js/TypeScript) that:
   - Runs on a schedule (every 15-30 minutes)
   - Fetches current prices for all tracked items
   - Compares to stored prices
   - Detects spikes (configurable threshold, e.g., >50% in 24h)
   - Sends FCM push notification to affected users
2. Set up FCM in the Flutter app
3. Build notification preferences screen
4. Build an "Alerts" tab showing triggered alerts with item details
5. Tap alert → navigate to item detail

**Cloud Function pseudocode:**
```typescript
// Scheduled function: runs every 15 minutes
export const checkPriceSpikes = functions.pubsub
  .schedule('every 15 minutes')
  .onRun(async () => {
    // 1. Get all unique items being tracked
    // 2. Fetch current prices in batches
    // 3. Compare to prices from 24h ago
    // 4. For items with >threshold% increase:
    //    - Find all users who own this item
    //    - Send FCM notification
    //    - Log the alert in Firestore
  });
```

**Key concepts to learn in Phase 5:**
- Firebase Cloud Functions (TypeScript)
- Scheduled functions (cron-like)
- Firebase Cloud Messaging setup (Android)
- Handling notifications in Flutter (foreground + background)
- Local notification display

**Recommended packages:**
```yaml
dependencies:
  firebase_messaging: ^15.0.0
  flutter_local_notifications: ^17.0.0
```

---

### Phase 6: Storage Unit Contents (Advanced)
**Goal:** Learn backend service architecture, GC communication

**Tasks:**
1. Set up a small Node.js service (Cloud Run or a VPS):
   - Uses `node-steam-user` to authenticate with Steam
   - Uses `node-globaloffensive` to connect to CS2 Game Coordinator
   - Exposes an API endpoint: `GET /storage/{casketId}/contents`
   - Returns items inside a storage unit
2. Flutter app calls this service after user authenticates
3. Sync storage unit contents to Firestore
4. Display storage unit contents in the app

**Reference implementation:** CaseMove (github.com/nombersDev/casemove)
- Desktop Electron app using same Node.js libraries
- Login via Steam credentials or browser token
- Uses `getCasketContents(casketId)` from node-globaloffensive
- Items in storage units have a `casket_id` field

**Key concepts to learn in Phase 6:**
- Cloud Run / container deployment
- Node.js backend basics
- API design (REST endpoints)
- Authentication between Flutter app and your backend
- The Steam Game Coordinator protocol (at a conceptual level)

---

## Project Structure

```
de_portfolio/
├── android/
├── ios/
├── lib/
│   ├── main.dart
│   ├── app.dart                    # App widget, router setup
│   ├── theme/
│   │   └── app_theme.dart          # Colors, text styles, dark mode
│   ├── models/
│   │   ├── cs2_item.dart           # Item data model
│   │   ├── storage_unit.dart       # Storage unit model
│   │   ├── price_data.dart         # Price/history model
│   │   └── user_profile.dart       # User settings model
│   ├── providers/
│   │   ├── inventory_provider.dart # Inventory state
│   │   ├── price_provider.dart     # Price data state
│   │   ├── auth_provider.dart      # Auth state
│   │   └── settings_provider.dart  # User preferences
│   ├── services/
│   │   ├── steam_api_service.dart  # Steam API calls
│   │   ├── price_service.dart      # Price fetching
│   │   ├── firestore_service.dart  # Firestore CRUD
│   │   └── notification_service.dart
│   ├── screens/
│   │   ├── home/
│   │   │   └── home_screen.dart
│   │   ├── inventory/
│   │   │   ├── inventory_screen.dart
│   │   │   └── item_detail_screen.dart
│   │   ├── storage/
│   │   │   └── storage_screen.dart
│   │   ├── alerts/
│   │   │   └── alerts_screen.dart
│   │   ├── auth/
│   │   │   └── login_screen.dart
│   │   └── settings/
│   │       └── settings_screen.dart
│   └── widgets/
│       ├── item_card.dart          # Reusable item display
│       ├── price_change_badge.dart # Green/red price indicator
│       ├── search_filter_bar.dart  # Search + filter chips
│       ├── price_chart.dart        # Price history chart
│       └── portfolio_summary.dart  # Value summary widget
├── functions/                      # Firebase Cloud Functions
│   ├── src/
│   │   ├── index.ts
│   │   └── priceChecker.ts
│   ├── package.json
│   └── tsconfig.json
├── pubspec.yaml
└── README.md
```

---

## Design Notes

- **Color scheme:** Use CS2's rarity colors as accents:
  - Consumer Grade: #B0C3D9
  - Industrial Grade: #5E98D9
  - Mil-Spec: #4B69FF
  - Restricted: #8847FF
  - Classified: #D32CE6
  - Covert: #EB4B4B
  - Extraordinary (★): #FFD700
- **Dark mode first** — most gamers prefer dark UI
- **Item images** from Steam CDN: `https://community.cloudflare.steamstatic.com/economy/image/{icon_url}`
- **Group duplicates** — show quantity badge instead of listing 50 identical items

---

## Getting Started (Phase 1 Commands)

```bash
# Create the Flutter project
flutter create de_portfolio --org com.yourname
cd de_portfolio

# Add initial dependencies
flutter pub add flutter_riverpod go_router cached_network_image google_fonts intl

# Verify setup
flutter run
```

---

## Learning Checkpoints

After each phase, you should be able to answer these without looking:

**Phase 1:**
- What's the difference between StatelessWidget and StatefulWidget?
- How does Riverpod's Provider differ from StateNotifierProvider?
- How does GoRouter handle named routes?
- What's the widget tree and how does Flutter render UI?

**Phase 2:**
- How does Firestore's document/collection model differ from SQL?
- What does a StreamBuilder do and when do you use it?
- How do Firestore security rules work?

**Phase 3:**
- How do you handle async operations in Dart (Future vs Stream)?
- What's json_serializable and why use code generation?
- How do you handle API pagination?

**Phase 4:**
- How do you transform raw data for chart display?
- What's the difference between a FutureProvider and StreamProvider?

**Phase 5:**
- How do Cloud Functions differ from a traditional server?
- How does FCM deliver notifications on Android?
- What's the difference between foreground and background notification handling?

**Phase 6:**
- What is the Steam Game Coordinator and why can't you skip it for storage units?
- How does a Flutter app communicate with a custom backend?
- What's Cloud Run and how does it differ from Cloud Functions?