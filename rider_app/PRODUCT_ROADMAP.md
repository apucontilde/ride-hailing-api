# Rider App Product Roadmap & API Implementation Plan

This document maps the existing API surface (from `RIDER_API_GUIDE.md`) to the required Flutter application screens and functionality. It identifies the gaps between the current implementation and a fully featured ride-hailing application.

---

## 🗺️ API-to-UI Mapping

### 1. Account & Identity (Auth/Profile)
**Goal:** Allow users to manage their identity, security, and payment methods.

| Screen | API Endpoints | User Story | Priority |
|---|---|---|---|
| **Reset Password** | `POST /auth/reset-password` | As a user, I want to set a new password after requesting a reset so I can regain access to my account. | High |
| **Account Verification** | `POST /auth/verify-email`, `POST /auth/verify-phone` | As a user, I want to verify my email and phone number to ensure my account is secure and eligible for rides. | Medium |
| **Profile Management** | `GET /rider/me`, `PUT /rider/me`, `PUT /rider/me/status` | As a user, I want to update my name, photo, and phone number to keep my profile current. | High |
| **Payment Methods** | `GET /rider/payment-methods`, `POST /rider/payment-methods`, `DELETE /rider/payment-methods/:id` | As a user, I want to add and manage my credit cards so I can pay for my rides seamlessly. | High |
| **Preferences** | `GET /rider/me/preferences`, `PUT /rider/me/preferences` | As a user, I want to set my default payment method or preferred vehicle type to speed up the booking process. | Low |
| **Account Deletion** | `DELETE /rider/me` | As a user, I want to be able to delete my account and data for privacy reasons. | Low |

---

### 2. Ride Lifecycle (The Core Experience)
**Goal:** The end-to-end process of requesting, tracking, and completing a ride.

| Screen | API Endpoints | User Story | Priority |
|---|---|---|---|
| **Ride Request** | `GET /estimates/price`, `POST /rides` | As a user, I want to search for a destination, see the estimated price, and request a ride. | ⚠️ (Partial - Destination selection failing) |
| **Driver Matching** | `GET /geo/nearby-drivers`, WebSocket `ride.offer` | As a user, I want to see that the system is searching for a driver and be notified when one accepts. | ✅ (Implemented) |
| **Active Ride Tracking** | `GET /rides/current`, `PUT /geo/rider/location`, WebSocket `driver.location` | As a user, I want to see the driver's real-time location and the ETA to my pickup point. | High |
| **In-Ride Controls** | `GET /rides/:id`, `POST /rides/:id/cancel` | As a user, I want to see ride details and have the ability to cancel the ride if necessary. | High |
| **Ride Completion** | `GET /rides/:id/receipt` | As a user, I want to see a detailed fare breakdown after my ride ends. | Medium |
| **Rating & Feedback** | `POST /rides/:id/rate` | As a user, I want to rate my driver to help maintain service quality. | Medium |

---

### 3. Activity & History
**Goal:** Provide transparency on past usage and spending.

| Screen | API Endpoints | User Story | Priority |
|---|---|---|---|
| **Ride History** | `GET /rides/history` | As a user, I want to see a list of all my past rides, including dates and costs. | Medium |
| **Ride Detail** | `GET /rides/:id` | As a user, I want to view the details of a past ride to remember the route or driver. | Low |

---

### 4. Safety & Support
**Goal:** Ensure user safety and provide assistance.

| Screen | API Endpoints | User Story | Priority |
|---|---|---|---|
| **Emergency SOS** | `POST /sos` | As a user, I want to trigger an SOS alert during a ride to notify emergency services or contacts. | High |
| **Feedback/Support** | `POST /feedback` | As a user, I want to send feedback or report an issue to the support team. | Low |

---

### 5. UI/UX Polish
**Goal:** Improve the overall feel and navigation of the application.

| Component | API Endpoints | User Story | Priority |
|---|---|---|---|
| **Main Menu Accordion** | N/A | As a user, I want a collapsible accordion menu to access settings, history, and profile without cluttering the main screen. | Medium |
## ⚙️ Missing Non-UI Functionality

Beyond screens, the following system-level functionalities must be implemented to fully utilize the API:

### 1. Device & Push Notification System
- **Device Registration:** Implement a boot/login sequence that calls `POST /devices` to register the device token for push notifications.
- **Notification Handlers:** Logic to handle `ride.updated` and `ride.offer` push notifications when the app is in the background.
- **Deep Linking:** Implement routing to open the `ActiveRideTrackingScreen` directly when a user taps a ride notification.

### 2. Background Location Services
- **Continuous Updates:** Use a background service (e.g., `flutter_background_service`) to update rider location via `PUT /geo/rider/location` while the app is minimized during an active ride.
- **Geofencing:** Trigger "Driver Arrived" notifications based on the driver's proximity to the pickup point.

### 3. WebSocket Lifecycle Management
- **Auto-Reconnect:** Implement a robust reconnection strategy for the `/ws` endpoint with exponential backoff.
- **Event Dispatcher:** A centralized event bus to route websocket messages (`ride.updated`, `driver.location`) to the appropriate providers.

### 4. Fare & Estimate Integration
- **Real-time Price Updates:** Periodically refresh `GET /estimates/price` if the user stays on the request screen for too long (to account for surge pricing).
- **Polyline Rendering:** Use `GET /navigation/route` to draw the actual road path on the map instead of straight lines.

---

## ⚠️ Technical Debt & Bug Fixes

Items that are not new features but critical for stability and correctness:

- **OSM 418 Error:** Investigate and resolve the "418 I'm a teapot" (or related rate-limiting/proxy) error when fetching OpenStreetMap tiles. Ensure proper User-Agent headers and cache strategies are implemented.
- **Ride Destination Bug:** Fix the "add destination fails" issue in the Ride Request flow to ensure users can successfully set their drop-off point.
- **Map Marker Performance:** Optimize the rendering of multiple driver markers to prevent UI lag during high-frequency WebSocket updates.
- **Auth Token Edge Cases:** Fix potential race conditions during token refresh in the `ApiClient` interceptor.

---

## 🚀 Implementation Roadmap

### Phase 1: Critical Path (The "Happy Path")
*Focus: Completing the core ride loop.*
1. **Fix Ride Destination Selection** (Critical bug fix)
2. **Active Ride Tracking Screen** (WebSocket integration + Map)
3. **Ride Cancellation** (In-ride controls)
4. **Profile Management** (Basic user info)
5. **Device Registration** (Push notifications)

### Phase 2: User Experience & Trust
*Focus: Transparency and security.*
1. **Ride History** (Past trips)
2. **Ride Receipts** (Fare breakdown)
3. **Rating System** (Post-ride feedback)
4. **Payment Methods** (Adding cards)

### Phase 3: Safety, Polish & Stability
*Focus: Edge cases, reliability, and UI refinements.*
1. **SOS Feature** (Emergency alerts)
2. **Background Location** (Continuous tracking)
3. **Account Verification** (Email/Phone)
4. **Preferences & Settings**
5. **OSM 418 Error Fix** (Map stability)
6. **Main Menu Accordion** (UI navigation polish)

---

## 🛠️ Technical Gaps to Bridge

| Gap | API Endpoint | Required Implementation |
|---|---|---|
| **Ride Lifecycle** | `GET /rides/current` | Integration with `ActiveRideNotifier` to update UI state |
| **Map Visualization** | `GET /navigation/route` | Integration with Google Maps/Mapbox to render polylines |
| **Real-time Updates** | WebSocket `driver.location` | Stream-based UI updates for driver marker movement |
| **Authentication** | `POST /auth/refresh` | Interceptor in `ApiClient` to handle 401 errors by rotating tokens |
| **Device Identity** | `POST /devices` | Integration with Firebase Cloud Messaging (FCM) for tokens |
