BEGIN;

-- ===================================================================
-- Test data for San José, Costa Rica area
-- Password for all users: SecurePass1
-- bcrypt hash: $2a$10$XuIJVMcV0IGpy6wEqlIAh.AxEnndN4EppspnD8kluLckebVAwRYlq
-- ===================================================================

-- Users -----------------------------------------------------------------
INSERT INTO users (id, email, phone, password_hash, role, status)
VALUES
  ('a0000000-0000-0000-0000-000000000001', 'rider1@test.com',  '+50680000001', '$2a$10$XuIJVMcV0IGpy6wEqlIAh.AxEnndN4EppspnD8kluLckebVAwRYlq', 'rider',  'active'),
  ('a0000000-0000-0000-0000-000000000002', 'rider2@test.com',  '+50680000002', '$2a$10$XuIJVMcV0IGpy6wEqlIAh.AxEnndN4EppspnD8kluLckebVAwRYlq', 'rider',  'active'),
  ('b0000000-0000-0000-0000-000000000001', 'driver1@test.com', '+50680000003', '$2a$10$XuIJVMcV0IGpy6wEqlIAh.AxEnndN4EppspnD8kluLckebVAwRYlq', 'driver', 'active'),
  ('b0000000-0000-0000-0000-000000000002', 'driver2@test.com', '+50680000004', '$2a$10$XuIJVMcV0IGpy6wEqlIAh.AxEnndN4EppspnD8kluLckebVAwRYlq', 'driver', 'active'),
  ('b0000000-0000-0000-0000-000000000003', 'driver3@test.com', '+50680000005', '$2a$10$XuIJVMcV0IGpy6wEqlIAh.AxEnndN4EppspnD8kluLckebVAwRYlq', 'driver', 'active'),
  ('c0000000-0000-0000-0000-000000000001', 'admin@test.com',  '+50680000006', '$2a$10$XuIJVMcV0IGpy6wEqlIAh.AxEnndN4EppspnD8kluLckebVAwRYlq', 'admin',  'active')
ON CONFLICT (id) DO NOTHING;

-- Riders ---------------------------------------------------------------
INSERT INTO riders (user_id, first_name, last_name, status)
VALUES
  ('a0000000-0000-0000-0000-000000000001', 'Ana',    'Garcia',  'idle'),
  ('a0000000-0000-0000-0000-000000000002', 'Carlos', 'Mendez',  'idle')
ON CONFLICT (user_id) DO NOTHING;

-- Drivers --------------------------------------------------------------
INSERT INTO drivers (user_id, first_name, last_name, status, onboarding_status, rating_summary)
VALUES
  ('b0000000-0000-0000-0000-000000000001', 'Diego',    'Jimenez',    'online', 'approved', '{"average": 4.8, "count": 42}'),
  ('b0000000-0000-0000-0000-000000000002', 'Maria',    'Rodriguez',  'online', 'approved', '{"average": 4.9, "count": 87}'),
  ('b0000000-0000-0000-0000-000000000003', 'Pedro',    'Sanchez',    'online', 'approved', '{"average": 4.5, "count": 15}')
ON CONFLICT (user_id) DO NOTHING;

-- Driver vehicles ------------------------------------------------------
INSERT INTO driver_vehicles (id, driver_id, make, model, color, year, plate_number, vehicle_type)
VALUES
  ('20000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001', 'Toyota',  'Camry',    'Blanco',  2020, 'BCC123',  'sedan'),
  ('20000000-0000-0000-0000-000000000002', 'b0000000-0000-0000-0000-000000000002', 'Hyundai', 'Tucson',   'Rojo',    2021, 'BCC456',  'suv'),
  ('20000000-0000-0000-0000-000000000003', 'b0000000-0000-0000-0000-000000000003', 'Mountain','Bike XC',  'Negro',   2023, 'BCC789',  'bicycle')
ON CONFLICT (id) DO NOTHING;

-- Driver documents -----------------------------------------------------
INSERT INTO driver_documents (id, driver_id, document_type, file_url, status)
VALUES
  ('60000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001', 'drivers_license',      'https://cdn.example.com/docs/d1-lic.pdf',    'approved'),
  ('60000000-0000-0000-0000-000000000002', 'b0000000-0000-0000-0000-000000000001', 'vehicle_insurance',    'https://cdn.example.com/docs/d1-ins.pdf',    'approved'),
  ('60000000-0000-0000-0000-000000000003', 'b0000000-0000-0000-0000-000000000002', 'drivers_license',      'https://cdn.example.com/docs/d2-lic.pdf',    'approved'),
  ('60000000-0000-0000-0000-000000000004', 'b0000000-0000-0000-0000-000000000002', 'vehicle_registration', 'https://cdn.example.com/docs/d2-reg.pdf',    'approved'),
  ('60000000-0000-0000-0000-000000000005', 'b0000000-0000-0000-0000-000000000003', 'drivers_license',      'https://cdn.example.com/docs/d3-lic.pdf',    'approved')
ON CONFLICT (id) DO NOTHING;

-- Driver positions (GEOGRAPHY points in San José area) ----------------
INSERT INTO driver_positions (driver_id, location, heading, speed, status)
VALUES
  ('b0000000-0000-0000-0000-000000000001',
   ST_GeogFromText('SRID=4326;POINT(-84.0907 9.9281)'), 180, 0, 'online'),    -- SJ downtown
  ('b0000000-0000-0000-0000-000000000002',
   ST_GeogFromText('SRID=4326;POINT(-84.1333 9.9167)'), 270, 25, 'online'),   -- Escazú
  ('b0000000-0000-0000-0000-000000000003',
   ST_GeogFromText('SRID=4326;POINT(-84.1167 10.0000)'), 90, 15, 'online')    -- Heredia
ON CONFLICT (driver_id) DO UPDATE SET
  location = EXCLUDED.location,
  heading = EXCLUDED.heading,
  speed = EXCLUDED.speed,
  status = EXCLUDED.status;

-- Rider positions ------------------------------------------------------
INSERT INTO rider_positions (rider_id, location)
VALUES
  ('a0000000-0000-0000-0000-000000000001',
   ST_GeogFromText('SRID=4326;POINT(-84.0833 9.9333)')),   -- Sabana Park
  ('a0000000-0000-0000-0000-000000000002',
   ST_GeogFromText('SRID=4326;POINT(-84.0500 9.9360)'))    -- UCR
ON CONFLICT (rider_id) DO UPDATE SET
  location = EXCLUDED.location;

-- Rider favorites ------------------------------------------------------
INSERT INTO rider_favorites (id, rider_id, name, lat, lng, address)
VALUES
  ('50000000-0000-0000-0000-000000000001',
   'a0000000-0000-0000-0000-000000000001', 'Casa',        9.9333, -84.0833, 'Sabana Sur, San José'),
  ('50000000-0000-0000-0000-000000000002',
   'a0000000-0000-0000-0000-000000000001', 'Universidad', 9.9360, -84.0500, 'UCR, San Pedro'),
  ('50000000-0000-0000-0000-000000000003',
   'a0000000-0000-0000-0000-000000000002', 'Trabajo',     9.9281, -84.0907, 'San José centro')
ON CONFLICT (id) DO NOTHING;

-- Rides ----------------------------------------------------------------
INSERT INTO rides (
  id, rider_id, driver_id, status,
  pickup_lat, pickup_lng, dropoff_lat, dropoff_lng,
  pickup_address, dropoff_address, vehicle_type,
  base_fare, distance_fare, time_fare, surge_multiplier, total_fare,
  requested_at, accepted_at, driver_arrived_at, started_at, completed_at
) VALUES (
  'd0000000-0000-0000-0000-000000000001',
  'a0000000-0000-0000-0000-000000000001',
  'b0000000-0000-0000-0000-000000000001',
  'completed',
  9.9333, -84.0833, 9.9360, -84.0500,
  'Sabana Park, San José', 'Universidad de Costa Rica, San Pedro',
  'sedan',
  1000, 2500, 500, 1.0, 4000,
  NOW() - INTERVAL '2 hours',
  NOW() - INTERVAL '1 hour 55 minutes',
  NOW() - INTERVAL '1 hour 50 minutes',
  NOW() - INTERVAL '1 hour 45 minutes',
  NOW() - INTERVAL '1 hour 30 minutes'
);

-- Ride events ----------------------------------------------------------
INSERT INTO ride_events (id, ride_id, from_status, to_status, actor, reason)
VALUES
  ('40000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000001',
   'pending', 'accepted', 'driver', 'Driver accepted the ride'),
  ('40000000-0000-0000-0000-000000000002', 'd0000000-0000-0000-0000-000000000001',
   'accepted', 'driver_arrived', 'driver', 'Driver arrived at pickup'),
  ('40000000-0000-0000-0000-000000000003', 'd0000000-0000-0000-0000-000000000001',
   'driver_arrived', 'in_progress', 'rider', 'Rider boarded the vehicle'),
  ('40000000-0000-0000-0000-000000000004', 'd0000000-0000-0000-0000-000000000001',
   'in_progress', 'completed', 'system', 'Ride completed successfully');

-- Ratings --------------------------------------------------------------
INSERT INTO ratings (id, ride_id, rater_role, rater_id, ratee_id, score, comment)
VALUES (
  'e0000000-0000-0000-0000-000000000001',
  'd0000000-0000-0000-0000-000000000001',
  'rider',
  'a0000000-0000-0000-0000-000000000001',
  'b0000000-0000-0000-0000-000000000001',
  5, 'Excelente servicio, muy puntual!'
);

-- Promotions -----------------------------------------------------------
INSERT INTO promotions (id, code, description, discount_type, discount_value, max_uses, current_uses, expires_at, is_active)
VALUES (
  '10000000-0000-0000-0000-000000000001',
  'WELCOME10',
  '10% off your first ride',
  'percentage',
  10.0,
  100,
  5,
  NOW() + INTERVAL '1 year',
  TRUE
);

-- SOS alerts -----------------------------------------------------------
INSERT INTO sos_alerts (id, user_id, user_role, ride_id, lat, lng, status, resolved_at)
VALUES (
  'f0000000-0000-0000-0000-000000000001',
  'a0000000-0000-0000-0000-000000000001',
  'rider',
  NULL,
  9.9333,
  -84.0833,
  'resolved',
  NOW() - INTERVAL '30 minutes'
);

-- Device tokens --------------------------------------------------------
INSERT INTO device_tokens (id, user_id, token, platform)
VALUES
  ('30000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', 'fcm-device-token-rider1',   'android'),
  ('30000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000002', 'fcm-device-token-rider2',   'ios'),
  ('30000000-0000-0000-0000-000000000003', 'b0000000-0000-0000-0000-000000000001', 'fcm-device-token-driver1',  'android'),
  ('30000000-0000-0000-0000-000000000004', 'b0000000-0000-0000-0000-000000000002', 'fcm-device-token-driver2',  'ios'),
  ('30000000-0000-0000-0000-000000000005', 'b0000000-0000-0000-0000-000000000003', 'fcm-device-token-driver3',  'android'),
  ('30000000-0000-0000-0000-000000000006', 'c0000000-0000-0000-0000-000000000001', 'fcm-device-token-admin',    'web')
ON CONFLICT (id) DO NOTHING;

COMMIT;
