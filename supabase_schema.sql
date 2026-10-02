-- ==============================================================================
-- SULTAN PYRAMIDS BOUTIQUE HOTEL VIEW (Giza, Egypt)
-- Authoritative Supabase PostgreSQL Schema & Operational Functions
-- Inventory: Exactly 13 Physical Rooms | 7 Standardized Categories
-- ==============================================================================

-- 1. EXTENSIONS
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
-- btree_gist enables exclusion constraints on scalar types like UUID + daterange
CREATE EXTENSION IF NOT EXISTS "btree_gist";

-- 2. TABLE: room_types (Standardized Room Categories)
CREATE TABLE IF NOT EXISTS public.room_types (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code VARCHAR(50) UNIQUE NOT NULL,
    name VARCHAR(100) NOT NULL,
    description TEXT,
    default_bed_config VARCHAR(50),
    default_max_occupancy INT,
    display_order INT DEFAULT 0,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- 3. TABLE: physical_rooms (Exactly 13 Physical Rooms)
CREATE TABLE IF NOT EXISTS public.physical_rooms (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    room_number VARCHAR(10) UNIQUE NOT NULL,
    room_type_id UUID NOT NULL REFERENCES public.room_types(id) ON DELETE RESTRICT,
    original_ota_name VARCHAR(255) NOT NULL,
    bed_configuration VARCHAR(50) NOT NULL, -- 'Double', 'Twin', 'Configurable'
    max_occupancy INT,                      -- Nullable: unconfirmed rooms require manager configuration
    operational_status VARCHAR(50) NOT NULL DEFAULT 'Operational'
        CHECK (operational_status IN ('Operational', 'Out of Service', 'Maintenance')),
    special_features TEXT[] DEFAULT '{}',   -- e.g. ARRAY['Jacuzzi', 'Panoramic Pyramids View']
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- 4. TABLE: operational_blocks (Maintenance & Out-of-Service periods)
CREATE TABLE IF NOT EXISTS public.operational_blocks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    physical_room_id UUID NOT NULL REFERENCES public.physical_rooms(id) ON DELETE CASCADE,
    start_date DATE NOT NULL,
    end_date DATE NOT NULL,
    reason TEXT NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'Active'
        CHECK (status IN ('Active', 'Completed', 'Cancelled')),
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now(),
    CONSTRAINT valid_block_date_range CHECK (end_date > start_date)
);

-- 5. TABLE: reservations
CREATE TABLE IF NOT EXISTS public.reservations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    external_booking_reference VARCHAR(100),
    guest_full_name VARCHAR(255) NOT NULL,
    guest_phone VARCHAR(50) NOT NULL,
    guest_email VARCHAR(255),
    check_in_date DATE NOT NULL,
    check_out_date DATE NOT NULL,
    adults INT NOT NULL DEFAULT 1 CHECK (adults > 0),
    children INT NOT NULL DEFAULT 0 CHECK (children >= 0),
    room_type_id UUID NOT NULL REFERENCES public.room_types(id) ON DELETE RESTRICT,
    physical_room_id UUID REFERENCES public.physical_rooms(id) ON DELETE RESTRICT,
    booking_source VARCHAR(50) NOT NULL
        CHECK (booking_source IN ('Booking.com', 'Agoda', 'Hotelbeds', 'Trip.com', 'Direct', 'Other')),
    reservation_status VARCHAR(50) NOT NULL DEFAULT 'Confirmed'
        CHECK (reservation_status IN ('Confirmed', 'Checked-in', 'Checked-out', 'Cancelled', 'No-show')),
    total_reservation_price NUMERIC(10, 2) NOT NULL DEFAULT 0.00 CHECK (total_reservation_price >= 0),
    currency VARCHAR(10) NOT NULL DEFAULT 'USD',
    payment_status VARCHAR(50) NOT NULL DEFAULT 'Unpaid'
        CHECK (payment_status IN ('Unpaid', 'Partially Paid', 'Paid', 'Refunded')),
    amount_paid NUMERIC(10, 2) NOT NULL DEFAULT 0.00 CHECK (amount_paid >= 0),
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now(),
    CONSTRAINT valid_reservation_dates CHECK (check_out_date > check_in_date)
);

-- 6. TABLE: audit_logs (Strict operational traceability)
CREATE TABLE IF NOT EXISTS public.audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID,
    entity_type VARCHAR(50) NOT NULL,
    entity_id UUID NOT NULL,
    action_type VARCHAR(50) NOT NULL,
    previous_values JSONB,
    new_values JSONB,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- 7. CONCURRENCY & OVERLAP PROTECTION
-- Exclusion constraint: prevents overlapping active reservations for the same room
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'no_overlapping_active_reservations'
    ) THEN
        ALTER TABLE public.reservations
        ADD CONSTRAINT no_overlapping_active_reservations
        EXCLUDE USING gist (
            physical_room_id WITH =,
            daterange(check_in_date, check_out_date, '[)') WITH &&
        )
        WHERE (reservation_status IN ('Confirmed', 'Checked-in', 'No-show') AND physical_room_id IS NOT NULL);
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'Exclusion constraint skipped or failed (will be enforced via trigger): %', SQLERRM;
END $$;

-- Fallback trigger for concurrency-safe overlap checking against active reservations and blocks
CREATE OR REPLACE FUNCTION public.fn_check_reservation_overlap()
RETURNS TRIGGER AS $$
DECLARE
    v_conflict_res UUID;
    v_conflict_block UUID;
    v_room_status VARCHAR(50);
    v_room_occupancy INT;
    v_room_type UUID;
BEGIN
    -- Only check active reservations assigned to a physical room
    IF NEW.physical_room_id IS NOT NULL AND NEW.reservation_status IN ('Confirmed', 'Checked-in', 'No-show') THEN
        -- Check room existence and operational status
        SELECT operational_status, max_occupancy, room_type_id
        INTO v_room_status, v_room_occupancy, v_room_type
        FROM public.physical_rooms
        WHERE id = NEW.physical_room_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Assigned physical room does not exist.';
        END IF;

        IF v_room_status <> 'Operational' THEN
            RAISE EXCEPTION 'Assigned physical room is currently % and cannot be assigned.', v_room_status;
        END IF;

        IF v_room_occupancy IS NULL THEN
            RAISE EXCEPTION 'Assigned physical room requires configuration of maximum occupancy before reservations can be assigned.';
        END IF;

        IF (NEW.adults + NEW.children) > v_room_occupancy THEN
            RAISE EXCEPTION 'Guest count (% guests) exceeds room maximum capacity of %.', (NEW.adults + NEW.children), v_room_occupancy;
        END IF;

        IF v_room_type <> NEW.room_type_id THEN
            RAISE EXCEPTION 'Assigned physical room does not belong to the selected room category.';
        END IF;

        -- Check reservation overlap (Check-in inclusive, Check-out exclusive)
        SELECT id INTO v_conflict_res
        FROM public.reservations
        WHERE physical_room_id = NEW.physical_room_id
          AND id <> COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::UUID)
          AND reservation_status IN ('Confirmed', 'Checked-in', 'No-show')
          AND check_in_date < NEW.check_out_date
          AND check_out_date > NEW.check_in_date
        LIMIT 1;

        IF v_conflict_res IS NOT NULL THEN
            RAISE EXCEPTION 'Reservation overlap detected with existing reservation % for the same room.', v_conflict_res;
        END IF;

        -- Check operational block overlap
        SELECT id INTO v_conflict_block
        FROM public.operational_blocks
        WHERE physical_room_id = NEW.physical_room_id
          AND status = 'Active'
          AND start_date < NEW.check_out_date
          AND end_date > NEW.check_in_date
        LIMIT 1;

        IF v_conflict_block IS NOT NULL THEN
            RAISE EXCEPTION 'Cannot assign room: overlaps with active operational block %.', v_conflict_block;
        END IF;
    END IF;

    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_validate_reservation_overlap ON public.reservations;
CREATE TRIGGER trg_validate_reservation_overlap
BEFORE INSERT OR UPDATE ON public.reservations
FOR EACH ROW
EXECUTE FUNCTION public.fn_check_reservation_overlap();

-- 8. AUDIT TRIGGER FOR RESERVATIONS
CREATE OR REPLACE FUNCTION public.fn_audit_reservation_changes()
RETURNS TRIGGER AS $$
DECLARE
    v_action VARCHAR(50);
BEGIN
    IF TG_OP = 'INSERT' THEN
        v_action := 'CREATE';
        INSERT INTO public.audit_logs (user_id, entity_type, entity_id, action_type, new_values)
        VALUES (auth.uid(), 'reservation', NEW.id, v_action, to_jsonb(NEW));
        RETURN NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        IF OLD.reservation_status <> NEW.reservation_status THEN
            v_action := 'STATUS_CHANGE: ' || NEW.reservation_status;
        ELSIF OLD.physical_room_id IS DISTINCT FROM NEW.physical_room_id THEN
            v_action := 'ROOM_REASSIGN';
        ELSIF OLD.check_in_date <> NEW.check_in_date OR OLD.check_out_date <> NEW.check_out_date THEN
            v_action := 'DATES_CHANGED';
        ELSE
            v_action := 'UPDATE';
        END IF;

        INSERT INTO public.audit_logs (user_id, entity_type, entity_id, action_type, previous_values, new_values)
        VALUES (auth.uid(), 'reservation', NEW.id, v_action, to_jsonb(OLD), to_jsonb(NEW));
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO public.audit_logs (user_id, entity_type, entity_id, action_type, previous_values)
        VALUES (auth.uid(), 'reservation', OLD.id, 'DELETE', to_jsonb(OLD));
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_audit_reservations ON public.reservations;
CREATE TRIGGER trg_audit_reservations
AFTER INSERT OR UPDATE OR DELETE ON public.reservations
FOR EACH ROW
EXECUTE FUNCTION public.fn_audit_reservation_changes();

-- 9. IDEMPOTENT SEED DATA: 7 CATEGORIES & 13 PHYSICAL ROOMS
-- Categories
INSERT INTO public.room_types (code, name, description, default_bed_config, default_max_occupancy, display_order)
VALUES
    ('side_pyramids_view', 'Side Pyramids View', 'Charming room with side pyramid vista and authentic atmosphere', 'Double', NULL, 1),
    ('standard_economy', 'Standard Economy, No View', 'Quiet and cost-effective accommodation without exterior view', 'Twin', NULL, 2),
    ('triple_view', 'Triple View', 'Spacious triple room overlooking the historic Giza pyramids', 'Configurable', 3, 3),
    ('direct_pyramids_view', 'Direct Pyramids View', 'Spectacular direct unobstructed view of the Great Pyramids', 'Double', NULL, 4),
    ('triple_no_view', 'Triple No View', 'Comfortable triple accommodation designed for quiet relaxation', 'Configurable', 3, 5),
    ('double_city_view', 'Double City View', 'Cozy double room with an open panorama of vibrant Giza city', 'Double', NULL, 6),
    ('jacuzzi_suite', 'Jacuzzi Suite with Panoramic Pyramids View', 'Luxury penthouse suite featuring a private jacuzzi and breathtaking panorama', 'Configurable', 5, 7)
ON CONFLICT (code) DO UPDATE
SET name = EXCLUDED.name,
    description = EXCLUDED.description,
    display_order = EXCLUDED.display_order;

-- Exactly 13 Physical Rooms
-- Note: Rooms without confirmed maximum occupancy are initialized with NULL max_occupancy
-- so they are visibly marked "Requires Configuration" and cannot be booked until manager configures them.
DO $$
DECLARE
    v_side_id UUID;
    v_econ_id UUID;
    v_trip_view_id UUID;
    v_dir_view_id UUID;
    v_trip_noview_id UUID;
    v_city_view_id UUID;
    v_jacuzzi_id UUID;
BEGIN
    SELECT id INTO v_side_id FROM public.room_types WHERE code = 'side_pyramids_view';
    SELECT id INTO v_econ_id FROM public.room_types WHERE code = 'standard_economy';
    SELECT id INTO v_trip_view_id FROM public.room_types WHERE code = 'triple_view';
    SELECT id INTO v_dir_view_id FROM public.room_types WHERE code = 'direct_pyramids_view';
    SELECT id INTO v_trip_noview_id FROM public.room_types WHERE code = 'triple_no_view';
    SELECT id INTO v_city_view_id FROM public.room_types WHERE code = 'double_city_view';
    SELECT id INTO v_jacuzzi_id FROM public.room_types WHERE code = 'jacuzzi_suite';

    -- Room 401
    INSERT INTO public.physical_rooms (room_number, room_type_id, original_ota_name, bed_configuration, max_occupancy, operational_status)
    VALUES ('401', v_side_id, 'Deluxe Double Room Side Pyramids View', 'Double', NULL, 'Operational')
    ON CONFLICT (room_number) DO UPDATE SET original_ota_name = EXCLUDED.original_ota_name;

    -- Room 402
    INSERT INTO public.physical_rooms (room_number, room_type_id, original_ota_name, bed_configuration, max_occupancy, operational_status)
    VALUES ('402', v_side_id, 'Deluxe Double Room Side Pyramids View', 'Double', NULL, 'Operational')
    ON CONFLICT (room_number) DO UPDATE SET original_ota_name = EXCLUDED.original_ota_name;

    -- Room 403
    INSERT INTO public.physical_rooms (room_number, room_type_id, original_ota_name, bed_configuration, max_occupancy, operational_status)
    VALUES ('403', v_side_id, 'Twin Room Side Pyramids View', 'Twin', NULL, 'Operational')
    ON CONFLICT (room_number) DO UPDATE SET original_ota_name = EXCLUDED.original_ota_name;

    -- Room 404
    INSERT INTO public.physical_rooms (room_number, room_type_id, original_ota_name, bed_configuration, max_occupancy, operational_status)
    VALUES ('404', v_econ_id, 'Standard Twin Room', 'Twin', NULL, 'Operational')
    ON CONFLICT (room_number) DO UPDATE SET original_ota_name = EXCLUDED.original_ota_name;

    -- Room 408
    INSERT INTO public.physical_rooms (room_number, room_type_id, original_ota_name, bed_configuration, max_occupancy, operational_status)
    VALUES ('408', v_econ_id, 'Standard Double Room', 'Double', NULL, 'Operational')
    ON CONFLICT (room_number) DO UPDATE SET original_ota_name = EXCLUDED.original_ota_name;

    -- Room 405
    INSERT INTO public.physical_rooms (room_number, room_type_id, original_ota_name, bed_configuration, max_occupancy, operational_status)
    VALUES ('405', v_trip_view_id, 'Triple Room Pyramids View', 'Configurable', 3, 'Operational')
    ON CONFLICT (room_number) DO UPDATE SET original_ota_name = EXCLUDED.original_ota_name, max_occupancy = 3;

    -- Room 406
    INSERT INTO public.physical_rooms (room_number, room_type_id, original_ota_name, bed_configuration, max_occupancy, operational_status)
    VALUES ('406', v_dir_view_id, 'Deluxe Double With Pyramids View', 'Double', NULL, 'Operational')
    ON CONFLICT (room_number) DO UPDATE SET original_ota_name = EXCLUDED.original_ota_name;

    -- Room 407
    INSERT INTO public.physical_rooms (room_number, room_type_id, original_ota_name, bed_configuration, max_occupancy, operational_status)
    VALUES ('407', v_dir_view_id, 'Deluxe Double With Pyramids View', 'Double', NULL, 'Operational')
    ON CONFLICT (room_number) DO UPDATE SET original_ota_name = EXCLUDED.original_ota_name;

    -- Room 409
    INSERT INTO public.physical_rooms (room_number, room_type_id, original_ota_name, bed_configuration, max_occupancy, operational_status)
    VALUES ('409', v_dir_view_id, 'Deluxe Double With Pyramids View', 'Double', NULL, 'Operational')
    ON CONFLICT (room_number) DO UPDATE SET original_ota_name = EXCLUDED.original_ota_name;

    -- Room 410
    INSERT INTO public.physical_rooms (room_number, room_type_id, original_ota_name, bed_configuration, max_occupancy, operational_status)
    VALUES ('410', v_trip_noview_id, 'Standard Triple Room', 'Configurable', 3, 'Operational')
    ON CONFLICT (room_number) DO UPDATE SET original_ota_name = EXCLUDED.original_ota_name, max_occupancy = 3;

    -- Room 411
    INSERT INTO public.physical_rooms (room_number, room_type_id, original_ota_name, bed_configuration, max_occupancy, operational_status)
    VALUES ('411', v_city_view_id, 'Deluxe Double Room With City View', 'Double', NULL, 'Operational')
    ON CONFLICT (room_number) DO UPDATE SET original_ota_name = EXCLUDED.original_ota_name;

    -- Room 501
    INSERT INTO public.physical_rooms (room_number, room_type_id, original_ota_name, bed_configuration, max_occupancy, operational_status, special_features)
    VALUES ('501', v_jacuzzi_id, 'Suite with Pyramids View', 'Configurable', 5, 'Operational', ARRAY['Jacuzzi', 'Panoramic Pyramids View'])
    ON CONFLICT (room_number) DO UPDATE SET original_ota_name = EXCLUDED.original_ota_name, max_occupancy = 5, special_features = ARRAY['Jacuzzi', 'Panoramic Pyramids View'];

    -- Room 502
    INSERT INTO public.physical_rooms (room_number, room_type_id, original_ota_name, bed_configuration, max_occupancy, operational_status, special_features)
    VALUES ('502', v_jacuzzi_id, 'Suite with Pyramids View', 'Configurable', 5, 'Operational', ARRAY['Jacuzzi', 'Panoramic Pyramids View'])
    ON CONFLICT (room_number) DO UPDATE SET original_ota_name = EXCLUDED.original_ota_name, max_occupancy = 5, special_features = ARRAY['Jacuzzi', 'Panoramic Pyramids View'];

END $$;

-- 10. ROW LEVEL SECURITY (RLS) POLICIES
ALTER TABLE public.room_types ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.physical_rooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.operational_blocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reservations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;

-- Allow authenticated hotel staff full operational access
DROP POLICY IF EXISTS "Staff access room_types" ON public.room_types;
CREATE POLICY "Staff access room_types" ON public.room_types
    FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Staff access physical_rooms" ON public.physical_rooms;
CREATE POLICY "Staff access physical_rooms" ON public.physical_rooms
    FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Staff access operational_blocks" ON public.operational_blocks;
CREATE POLICY "Staff access operational_blocks" ON public.operational_blocks
    FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Staff access reservations" ON public.reservations;
CREATE POLICY "Staff access reservations" ON public.reservations
    FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Staff access audit_logs" ON public.audit_logs;
CREATE POLICY "Staff access audit_logs" ON public.audit_logs
    FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Anonymous read-only policy for initial pre-login handshake or health diagnostics
-- Note: Guest data in reservations is NOT readable by anon
DROP POLICY IF EXISTS "Anon read room_types" ON public.room_types;
CREATE POLICY "Anon read room_types" ON public.room_types
    FOR SELECT TO anon USING (true);

DROP POLICY IF EXISTS "Anon read physical_rooms" ON public.physical_rooms;
CREATE POLICY "Anon read physical_rooms" ON public.physical_rooms
    FOR SELECT TO anon USING (true);
