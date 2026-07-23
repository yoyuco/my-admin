-- Fix: finish_work_session_idem_v1 để đơn không bị kẹt vĩnh viễn ở 'in_progress'
--
-- Bối cảnh:
--   Khi kết thúc work_session, hàm chỉ chuyển đơn khỏi 'in_progress' nếu đọc được
--   SERVICE_TYPE của variant ('Pilot' -> pending_pilot, 'Selfplay' -> paused_selfplay).
--   Nếu SERVICE_TYPE là NULL/không nhận diện (ví dụ variant bị tạo thiếu attribute
--   SERVICE_TYPE), KHÔNG nhánh nào chạy -> đơn kẹt lại 'in_progress' mà không có ai
--   đang làm (không có work_session mở). Đây là nguyên nhân của các đơn "đang làm
--   nhưng không có người làm".
--
-- Thay đổi:
--   Thêm nhánh ELSE fallback: đưa đơn về 'paused_selfplay' (trạng thái tạm dừng an toàn,
--   đơn quay lại hàng chờ để được nhận lại) và RAISE WARNING để lỗi dữ liệu lộ diện
--   thay vì bị nuốt im lặng. Phần còn lại của hàm giữ nguyên.

CREATE OR REPLACE FUNCTION public.finish_work_session_idem_v1(p_session_id uuid, p_outputs jsonb, p_activity_rows jsonb, p_overrun_reason text, p_idem_key text, p_overrun_type text, p_overrun_proof_urls text[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_session public.work_sessions%ROWTYPE;
    v_order_line_id UUID;
    v_order_id UUID;
    v_service_type TEXT;
    output_item JSONB;
    activity_item JSONB;
    v_delta NUMERIC;
    v_current_order_status TEXT;
    v_context jsonb;
BEGIN
    -- 1. Lấy thông tin phiên và kiểm tra quyền (như cũ)
    SELECT * INTO v_session FROM public.work_sessions WHERE id = p_session_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Phiên làm việc không tồn tại.'; END IF;
    IF v_session.ended_at IS NOT NULL THEN RETURN; END IF;

    v_order_line_id := v_session.order_line_id;
    SELECT o.id INTO v_order_id FROM public.order_lines ol JOIN public.orders o ON ol.order_id = o.id WHERE ol.id = v_order_line_id;

    SELECT jsonb_build_object('game_code', o.game_code, 'business_area_code', 'SERVICE')
    INTO v_context
    FROM public.order_lines ol JOIN public.orders o ON ol.order_id = o.id
    WHERE ol.id = v_order_line_id;

    IF v_session.farmer_id <> public.get_current_profile_id() AND NOT has_permission('work_session:override', v_context) THEN
        RAISE EXCEPTION 'Bạn không phải chủ phiên và không có quyền can thiệp.';
    END IF;

    -- 2. Xử lý outputs và activities trước tiên
    IF p_outputs IS NOT NULL THEN
        FOR output_item IN SELECT * FROM jsonb_array_elements(p_outputs) LOOP
            v_delta := (output_item->>'current_value')::numeric - (output_item->>'start_value')::numeric;
            IF v_delta <> 0 THEN
                INSERT INTO public.work_session_outputs (work_session_id, order_service_item_id, start_value, delta, start_proof_url, end_proof_url, params)
                VALUES (p_session_id, (output_item->>'item_id')::uuid, (output_item->>'start_value')::numeric, v_delta, output_item->>'start_proof_url', output_item->>'end_proof_url', output_item->'params');

                UPDATE public.order_service_items SET done_qty = done_qty + v_delta WHERE id = (output_item->>'item_id')::uuid;
            END IF;
        END LOOP;
    END IF;

    IF p_activity_rows IS NOT NULL THEN
        FOR activity_item IN SELECT * FROM jsonb_array_elements(p_activity_rows) LOOP
            INSERT INTO public.work_session_outputs(work_session_id, order_service_item_id, delta, params)
            VALUES (p_session_id, (activity_item->>'item_id')::uuid, (activity_item->>'delta')::numeric, activity_item->'params');
        END LOOP;
    END IF;

    -- 3. Đánh dấu phiên làm việc đã kết thúc
    UPDATE public.work_sessions
    SET ended_at = now(), overrun_reason = p_overrun_reason, overrun_type = p_overrun_type, overrun_proof_urls = p_overrun_proof_urls
    WHERE id = p_session_id;

    -- 4. <<< LOGIC MỚI: Cập nhật trạng thái đơn hàng Ở CUỐI CÙNG >>>
    -- Đọc lại trạng thái mới nhất của đơn hàng (có thể đã bị trigger thay đổi)
    SELECT o.status,
           (SELECT a.name FROM product_variant_attributes pva JOIN attributes a ON pva.attribute_id = a.id WHERE pva.variant_id = ol.variant_id AND a.type = 'SERVICE_TYPE' LIMIT 1)
    INTO v_current_order_status, v_service_type
    FROM public.order_lines ol JOIN public.orders o ON ol.order_id = o.id
    WHERE ol.id = v_order_line_id;

    -- Chỉ cập nhật nếu trạng thái vẫn còn là 'in_progress'
    IF v_current_order_status = 'in_progress' THEN
        IF v_service_type IN ('Service - Pilot', 'Pilot') THEN
            UPDATE public.orders SET status = 'pending_pilot' WHERE id = v_order_id;
        ELSIF v_service_type IN ('Service - Selfplay', 'Selfplay') THEN
            UPDATE public.orders SET status = 'paused_selfplay' WHERE id = v_order_id;
        ELSE
            -- Fallback phòng hờ: SERVICE_TYPE bị NULL/không nhận diện được
            -- (ví dụ variant thiếu attribute SERVICE_TYPE). Trước đây rơi vào đây sẽ
            -- khiến đơn kẹt vĩnh viễn ở 'in_progress'. Đưa về trạng thái tạm dừng an
            -- toàn để đơn quay lại hàng chờ, đồng thời cảnh báo để phát hiện lỗi dữ liệu.
            UPDATE public.orders SET status = 'paused_selfplay' WHERE id = v_order_id;
            RAISE WARNING 'finish_work_session_idem_v1: order % có SERVICE_TYPE không xác định (v_service_type=%), đã fallback về paused_selfplay. Kiểm tra attribute SERVICE_TYPE của variant.', v_order_id, v_service_type;
        END IF;
    END IF;

    -- 5. Xử lý logic Pilot Cycle (giữ nguyên)
    -- Đọc lại status một lần nữa để chắc chắn
    SELECT status INTO v_current_order_status FROM public.orders WHERE id = v_order_id;
    IF v_service_type IN ('Service - Pilot', 'Pilot') AND
       v_current_order_status NOT IN ('completed', 'cancelled', 'delivered', 'pending_completion') THEN

        UPDATE order_lines
        SET paused_at = CASE WHEN v_current_order_status = 'customer_playing' THEN paused_at ELSE now() END
        WHERE id = v_order_line_id;

        PERFORM public.update_pilot_cycle_warning(v_order_line_id);
        PERFORM public.check_and_reset_pilot_cycle(v_order_line_id);
    END IF;
END;
$function$;
