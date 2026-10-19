do not dismiss offer by clicking away, only by clicking reject/pass

on login rider and driver app restore inprogress trip

login does not persits between reloads on both apps web

instead of driver clicks button "Arrived at pickup", the driver position update is checked for distance to pickup, and the rider is notified when the driver is nerby and when the driver arrrives. State of trip on both apps is advanced automatically.

Change destination is pushed to driver via WS.

Change destination displays new estimate with confirmation windows for rider before actually cahnging the destination after the rider picks new destination.

driver app, enter to login not working on web

driver app new ride popup shows destination, distance and time estimmates.

Rider app status is "Matching"after driver clicks Arrived at pickp. It should say waiting for driver or something like that.

rider app gets something to mark the stops bbefore destination

driver app map shows only next stop, all stops can be seen in the bottom drawer

zoom to fit all stops buugged in android

on cancel ride request, previous inputs and stops are refilled,

offer expired is shown when offer was just accepted on android

both driver an rider should have a current location button on bot right, that zooms to fit route, then to the current location on subsequent clicks


arrived at location deosnt work if driver alteady at location

if trip is cancelled, rider should get a screen with details

future plan(defered) cancellation reasion question after or before cancellation for both rider and driver

driver accepted cancelled trip, after multiple quick request canell reuest from rider
26/10/19 15:45:24 [DEBUG] REQ POST /api/v1/rides/83ccb6f7-b785-4dda-969b-b885058c8aed/cancel 
request_id=fa29d48b7569845ca1d0ea7b14788f37
2026/10/19 15:45:24 [DEBUG] RES POST /api/v1/rides/83ccb6f7-b785-4dda-969b-b885058c8aed/cancel 
=> 200 request_id=fa29d48b7569845ca1d0ea7b14788f37 resp_body={"ride":{"id":"83ccb6f7-b785-4dda-969b-b885058c8aed","rider_id":"a0000000-0000-0000-0000-000000000001","driver_id":null,"status":"cancelled","pickup_lat":9.9347733,"pickup_lng":-84.07823,"dropoff_lat":9.9373412,"dropoff_lng":-84.0619343,"pickup_address":"Current Location","dropoff_address":"Los Yoses","vehicle_type":"suv","cancellation_fee":0,"base_fare":8,"distance_fare":4.409097855413209,"time_fare":2.2633333333333336,"surge_multiplier":1.5,"total_fare":22.01,"fare_region_id":"cr-sj","fare_rate_id":"6af42b1f-3fa0-4a6a-b9ae-a0c910484617","fare_currency":"USD","grade_uplift_pct":0.0302,"grade_ascent_m":44.63964571687734,"actual_duration_s":null,"actual_distance_m":null,"requested_at":"2026-10-19T21:44:39.652182Z","accepted_at":null,"driver_arrived_at":null,"started_at":null,"completed_at":null,"cancelled_at":null,"created_at":"2026-10-19T21:44:39.652182Z","updated_at":"2026-10-19T21:44:39.652182Z"}}
[GIN] 2026/10/19 - 15:45:24 | 200 |  10.77ms |    172.20.240.1 | POST     "/api/v1/rides/83ccb6f7-b785-4dda-969b-b885058c8aed/cancel"
2026/10/19 15:45:26 [DEBUG] REQ POST /api/v1/driver/rides/83ccb6f7-b785-4dda-969b-b885058c8aed/cancel request_id=f86463163adf08bf4cdcd0755fb54abe
2026/10/19 15:45:26 [DEBUG] RES POST /api/v1/driver/rides/83ccb6f7-b785-4dda-969b-b885058c8aed/cancel => 400 request_id=f86463163adf08bf4cdcd0755fb54abe resp_body={"error":{"code":"BAD_REQUEST","message":"ride cannot be cancelled"}}
2026/10/19 15:45:26 [ERROR] POST /api/v1/driver/rides/83ccb6f7-b785-4dda-969b-b885058c8aed/cancel => 400 request_id=f86463163adf08bf4cdcd0755fb54abe error=ride cannot be cancelled in current status
[GIN] 2026/10/19 - 15:45:26 | 400 |   1.72ms |    172.20.240.1 | POST     "/api/v1/driver/rides/83ccb6f7-b785-4dda-969b-b885058c8aed/cancel"
Error #01: ride cannot be cancelled in current status
2026/10/19 15:45:29 [dispatch] liveness sweep: 1 driver(s) marked offline (no presence refresh 
in 30s)
2026/10/19 15:45:35 failed to handle ride accept: no active offer for ride 83ccb6f7-b785-4dda-969b-b885058c8aed
2026/10/19 15:45:36 [DEBUG] REQ POST /api/v1/driver/rides/83ccb6f7-b785-4dda-969b-b885058c8aed/cancel request_id=4a3409325fff8937e71244c105d92d2b
2026/10/19 15:45:36 [DEBUG] RES POST /api/v1/driver/rides/83ccb6f7-b785-4dda-969b-b885058c8aed/cancel => 400 request_id=4a3409325fff8937e71244c105d92d2b resp_body={"error":{"code":"BAD_REQUEST","message":"ride cannot be cancelled"}}
2026/10/19 15:45:36 [ERROR] POST /api/v1/driver/rides/83ccb6f7-b785-4dda-969b-b885058c8aed/cancel => 400 request_id=4a3409325fff8937e71244c105d92d2b error=ride cannot be cancelled in current status
[GIN] 2026/10/19 - 15:45:36 | 400 |  11.18ms |    172.20.240.1 | POST     "/api/v1/driver/rides/83ccb6f7-b785-4dda-969b-b885058c8aed/cancel"
Error #01: ride cannot be cancelled in current status
^Csignal: interrupt


found” ride stays pending forever and the rider never receives the terminal update. The API plan makes a DB-backed test a required gate.

Any authenticated driver can currently accept any pending ride by UUID, and any authenticated user can cancel any ride by UUID; the canonical funnel/ownership work closes both.
Concurrent work exists that this orchestration did not author: untracked api_plans/01_[arrival]_accept_time_evaluation.md and uncommitted _publishArrivalFix changes in driver_app/lib/features/trip/presentation/trip_screen.dart + its test. The driver plan explicitly preserves them; the arrival plan adopts the rides CAS.
Android/device and some Flutter web behaviors remain UNVERIFIABLE in this WSL harness; closing commands are in the plans (melos run analyze, melos run test; Go make test/make lint/make test-integration).
Implementation order is API plan first; the rider and driver 01_ plans depend on it. No git add/commit was run.